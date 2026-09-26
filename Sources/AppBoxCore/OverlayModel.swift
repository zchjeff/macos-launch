import Foundation
import Observation

/// 网格的列数。视图画格子与键盘上下跨行都用它——两处必须是同一个数，
/// 否则高亮会落在与眼睛看到的不同的位置上。
public enum OverlayGrid {
    public static let columns = 7
}

/// 键盘要挪的方向。
public enum GridDirection: Sendable, CaseIterable {
    case left, right, up, down
}

/// 高亮在网格里的移动规则。纯函数，不持有状态，方便按列数逐个验。
public enum GridNavigation {
    /// 从 `index` 往某个方向挪一格。
    ///
    /// 规则：左右在同一行内移动，上下跨一行——**到边停住，不回绕**。
    /// 回绕会让「按一下左」跳到上一行的末尾，位置变化不可预期；
    /// 停住则每次按键位移最多一格（或一行），手感和眼睛都好跟。
    /// 末行不满时也不丢项：最后一行第 k 个总能从上一行第 k 列按下到达。
    ///
    /// 越界的 `index`（快照刚变小时可能来不及夹）先夹回 `0..<count` 再算，
    /// 所以调用方不需要自己保证范围。
    public static func destination(
        from index: Int,
        direction: GridDirection,
        count: Int,
        columns: Int
    ) -> Int {
        guard count > 0, columns > 0 else { return 0 }
        let current = min(max(index, 0), count - 1)
        let column = current % columns

        switch direction {
        case .left:
            return column > 0 ? current - 1 : current
        case .right:
            return column < columns - 1 && current + 1 < count ? current + 1 : current
        case .up:
            return current - columns >= 0 ? current - columns : current
        case .down:
            return current + columns < count ? current + columns : current
        }
    }
}

/// 高亮项被回车时要做的事。启动与展开是两条不同的路，这里只判类型，
/// 真正的动作由覆盖层控制器接。
public enum OverlayActivation: Equatable, Sendable {
    case launch(ApplicationEntry)
    case openGroup(String)
}

/// 覆盖层的导航状态：顶层 ↔ 某个分组的子网格，以及键盘高亮落在那儿。
///
/// 它不放在视图里，有两个原因。一是覆盖层的视图在快照变化时会被整体重建，
/// 状态放在视图里会在某次后台刷新后悄悄丢掉；二是「Esc 的两级语义」和
/// 「点空白先回顶层、在顶层才收起」是需要被钉住的行为，放在这里才测得到。
@MainActor
@Observable
public final class OverlayModel {
    /// 当前在哪儿。子网格记的是分组 id，不是分组本身——快照会换，分组对象也会换。
    public enum Level: Equatable, Sendable {
        case top
        case group(String)
    }

    public private(set) var level: Level = .top

    /// 键盘高亮在当前这一层的第几个格子。空层（比如空分组的子网格）没有格子可点，
    /// 界面据此不画高亮，回车也什么都不会发生。
    public private(set) var selection = 0

    /// 进子网格之前顶层的高亮。返回时放回去——否则展开一个方块再回来，
    /// 高亮会跑到第一个应用上，紧接着按回车启动的就是另一个东西了。
    private var topSelection = 0

    /// 搜索框里的文字。空串表示没在搜索。
    public private(set) var query = ""

    /// 当前查询命中的应用。没在搜索时是空的。
    public private(set) var searchResults: [ApplicationEntry] = []

    /// 查询非空即搜索中。它是独立的一份状态：`query` 改完还要等
    /// `updateSearch(in:)` 把结果算出来，两者之间隔着一次快照查询。
    public private(set) var isSearching = false

    /// 进搜索之前的高亮。清空查询后放回去，和子网格那套记忆同一道理。
    private var selectionBeforeSearch = 0

    /// 让搜索框抢焦点的令牌：控制器每次需要时 +1，视图监听它把焦点塞进输入框。
    /// 焦点是视图的状态，但"什么时候该有焦点"由按键路径决定，两边就靠这个数对齐。
    public private(set) var focusRequest = 0

    public init() {}

    /// 展开某个分组的子网格。
    public func open(groupID: String) {
        topSelection = selection
        level = .group(groupID)
        selection = 0
    }

    /// 返回上一层。**返回是否消费了这次返回**——已经在顶层就是 false，
    /// 调用方（Esc 与点空白）据此决定要不要接着收起覆盖层。
    @discardableResult
    public func back() -> Bool {
        guard level != .top else { return false }
        level = .top
        selection = topSelection
        return true
    }

    /// 每次唤起都从顶层开始，高亮从头来，上次的搜索也忘干净。
    public func reset() {
        level = .top
        selection = 0
        topSelection = 0
        query = ""
        searchResults = []
        isSearching = false
        selectionBeforeSearch = 0
    }

    /// 挪一格高亮。`tiles` 是当前这一层的格子，由调用方从快照里取。
    public func move(_ direction: GridDirection, columns: Int, in tiles: [OverlayTile]) {
        selection = GridNavigation.destination(
            from: selection,
            direction: direction,
            count: tiles.count,
            columns: columns
        )
    }

    /// 高亮项被回车时该干什么。没有高亮项（空层）时是 nil。
    public func activation(in tiles: [OverlayTile]) -> OverlayActivation? {
        guard tiles.indices.contains(selection) else { return nil }
        switch tiles[selection] {
        case .application(let entry): return .launch(entry)
        case .folder(let folder): return .openGroup(folder.id)
        }
    }

    // MARK: - 搜索

    /// 输入一段文字（一个按键字符，或粘贴进来的一串）。
    public func type(_ text: String) {
        query += text
    }

    /// 整段换掉查询：输入框把编辑后的全文交给模型时走它（选中替换、粘贴、输入法改字）。
    public func replaceQuery(_ text: String) {
        query = text
    }

    /// 退格删掉最后一个字符。
    public func deleteLastQueryCharacter() {
        query = String(query.dropLast())
    }

    /// 清掉查询但不换层：结果与高亮由 `updateSearch` 一并复原。
    public func clearSearch() {
        query = ""
    }

    /// 按当前查询重算结果，顺带管进出搜索两头的状态。
    ///
    /// 查询从空变非空：进入搜索，把这一层的高亮记下来、高亮落到第一个结果上；
    /// 从非空变空：退出搜索，层级不动，高亮放回原处。
    /// 幂等——视图与控制器都可能触发它，重复调用不会把记忆搅乱。
    public func updateSearch(in snapshot: LibrarySnapshot) {
        guard !query.isEmpty else {
            guard isSearching else { return }
            isSearching = false
            searchResults = []
            selection = selectionBeforeSearch
            return
        }

        if !isSearching {
            isSearching = true
            selectionBeforeSearch = selection
            selection = 0
        }
        searchResults = AppSearch.results(for: query, in: snapshot)
        selection = OverlayModel.clamped(selection, to: searchResults.count)
    }

    /// 当前该显示、该导航的格子：搜索时是结果清单，否则是这一层自己的。
    /// 画出来的和键盘走的必须是同一份。
    public func tiles(in snapshot: LibrarySnapshot) -> [OverlayTile] {
        isSearching ? searchResults.map(OverlayTile.application) : snapshot.tiles(at: level)
    }

    /// 覆盖层需要搜索框拿焦点时喊一声。
    public func requestSearchFocus() {
        focusRequest += 1
    }

    /// 换了快照之后对一遍三件事。
    ///
    /// 一是打开的分组如果没了（在控制台里被删掉），退回顶层——不这么做的话，
    /// 覆盖层会停在一个「打开着但画不出东西」的状态里，用户看到的是一张顶层
    /// 网格，按 Esc 却要先「返回」一次才收得起来。
    ///
    /// 二是把高亮夹回格子数以内：应用被删掉或移出分组之后，
    /// 高亮不能停在一个点不到的位置上。搜索中夹的是结果清单。
    ///
    /// 三是搜索中的结果重算一遍：新装的应用立刻可搜，删掉的当场消失。
    public func reconcile(with snapshot: LibrarySnapshot) {
        if case .group(let id) = level, !snapshot.groups.contains(where: { $0.group.id == id }) {
            level = .top
            if !isSearching { selection = topSelection }
        }

        topSelection = OverlayModel.clamped(topSelection, to: snapshot.topLevelTiles.count)
        if isSearching {
            searchResults = AppSearch.results(for: query, in: snapshot)
            selection = OverlayModel.clamped(selection, to: searchResults.count)
        } else {
            selection = OverlayModel.clamped(selection, to: snapshot.tiles(at: level).count)
        }
    }

    private static func clamped(_ index: Int, to count: Int) -> Int {
        count > 0 ? min(max(index, 0), count - 1) : 0
    }
}
