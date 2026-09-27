import Foundation
import Observation

/// 控制台左侧选中的东西：某个分组，或者「失效应用」那一栏。
///
/// 用枚举而不是一个约定的字符串 id：失效列表不是分组，硬塞进分组列表就得靠
/// 「某个特殊的 id」来区分，那种东西迟早会被当成普通分组处理。
public enum ConsoleSelection: Hashable, Sendable {
    case group(String)
    case missing
}

/// 控制台的视图模型。
///
/// 放在领域层是为了可测：「点了这个按钮会调什么、失败了会说什么」是这个切片真正的新逻辑，
/// 不该只能靠手点界面来验证。视图只负责把控件接到这些方法上。
///
/// 全部改动都经 `LibraryService` 落盘后才反映到界面上——视图模型自己不持有配置副本，
/// 每轮操作结束重新问一次快照，内存与磁盘就不会各说各话。
@MainActor
@Observable
public final class ConsoleModel {
    /// 分组结构，顺序即界面顺序。
    public private(set) var groups: [GroupSnapshot] = []
    /// 配置里有、磁盘上找不到的应用。
    public private(set) var missing: [MissingApplication] = []
    /// 左侧选中项。界面直接双向绑定。
    ///
    /// 换选中项时顺手清掉右侧选中的应用：两栏是联动的，分组一换，
    /// 原先选中的那个应用多半不在新列表里，详情面板不该继续显示它。
    public var selection: ConsoleSelection? {
        get { storedSelection }
        set {
            storedSelection = newValue
            if let selectedApplicationID, !isListed(selectedApplicationID) {
                self.selectedApplicationID = nil
            }
        }
    }

    private var storedSelection: ConsoleSelection?
    /// 右侧列表里选中的应用——详情面板显示的就是它。
    public var selectedApplicationID: String?
    /// 组内搜索的查询词。纯视图状态：过滤只影响「看得见哪些」，
    /// 顺序、成员这些事实仍由 `applications` 那份完整列表说话。
    public var query = ""
    /// 待确认的删除。界面据此弹确认框——**确认之前一个字节都不写**。
    public var pendingDeletion: GroupSnapshot?
    /// 待确认的清理。
    public var pendingForget: MissingApplication?
    /// 最近一次失败的说法。nil 表示没有未处理的错误。
    public private(set) var errorMessage: String?
    /// 首轮加载中（冷扫描要几百毫秒，界面得有点表示）。
    public private(set) var isLoading = false
    /// 正在跑的引导整理。nil 表示向导没在界面上。
    public private(set) var setup: SetupWizardModel?
    /// 开机启动开关的界面状态。每次操作后按端口（系统真源）回填——
    /// 注册失败时它会弹回原样，界面不会说谎。
    public private(set) var isOpenAtLogin = false

    private let service: LibraryService
    private let loginItem: any LoginItemControlling

    public init(service: LibraryService, loginItem: any LoginItemControlling = .disabled) {
        self.service = service
        self.loginItem = loginItem
        self.isOpenAtLogin = loginItem.status
    }

    // MARK: - 读

    /// 选中的分组 id；当前选的是「失效应用」时为 nil。
    public var selectedGroupID: String? {
        if case .group(let id) = selection { return id }
        return nil
    }

    /// 选中分组里的应用，顺序就是界面上的顺序。隐藏的应用也在其中——
    /// 控制台要能看到它们、把它们恢复回来。
    public var applications: [ApplicationEntry] {
        groups.first { $0.group.id == selectedGroupID }?.applications ?? []
    }

    /// 当前分组里命中查询的应用；查询为空就是完整列表。
    /// 隐藏的应用在控制台照常参与过滤——隐藏只管覆盖层，不管这里。
    public var filteredApplications: [ApplicationEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return applications }
        return applications.filter { AppSearch.matches(query: trimmed, entry: $0) }
    }

    public var selectedGroup: Group? {
        groups.first { $0.group.id == selectedGroupID }?.group
    }

    /// 详情面板的内容。失效记录与在场的应用共用一套字段，界面不必分两套画。
    public var detail: ApplicationDetail? {
        guard let selectedApplicationID else { return nil }

        if case .missing = selection {
            guard let record = missing.first(where: { $0.bundleIdentifier == selectedApplicationID }) else {
                return nil
            }
            return ApplicationDetail(record, groupName: groupName(ofGroup: record.groupID))
        }

        guard let entry = applications.first(where: { $0.bundleIdentifier == selectedApplicationID }) else {
            return nil
        }
        return ApplicationDetail(entry, groupName: selectedGroup?.name)
    }

    /// 删除确认框要说的那句话。
    ///
    /// 说清楚会动到多少个应用，是因为「删分组」听起来像只删一个壳，
    /// 用户得在点确认之前就知道有 N 个应用要挪窝。
    public var deleteConfirmationMessage: String? {
        guard let pendingDeletion else { return nil }
        return "「\(pendingDeletion.group.name)」里的 \(pendingDeletion.applications.count) 个应用"
            + "将移入「未分类」，分组本身会被删除。应用不会被卸载。"
    }

    /// 清理确认框要说的那句话：说清楚会丢掉哪些设置。
    public var forgetConfirmationMessage: String? {
        guard let pendingForget else { return nil }
        return "「\(pendingForget.alias ?? pendingForget.bundleIdentifier)」的别名、分组、"
            + "隐藏等设置都会被清掉。不会卸载或删除任何应用。"
    }

    // MARK: - 同步

    /// 重新读一遍分组结构。
    ///
    /// 扫描是阻塞的（冷启动近半秒），所以放到主线程外做，回主线程再赋值——
    /// 否则控制台一打开就整窗卡住。
    ///
    /// 顺便记下每个已跟踪应用这次出现的位置：等哪天它不见了，「失效」列表才有话可说。
    /// 开控制台是低频操作，这点写入不值得省。
    public func refresh() async {
        isLoading = true
        let service = self.service
        let snapshot = await Task.detached(priority: .userInitiated) {
            service.snapshot(recordingPaths: true)
        }.value
        isLoading = false
        apply(snapshot)
    }

    public func dismissError() {
        errorMessage = nil
    }

    // MARK: - 引导整理

    /// 进入引导整理。
    ///
    /// 建议取自「未分类」里的应用：首启时配置是空的，扫到的应用全在那儿；
    /// 即便之后再进向导，要整理的本来也还是这批还没归位的。
    public func beginSetup() async {
        await refresh()
        guard let ungrouped = groups.first(where: { $0.group.isUngrouped }) else { return }
        setup = SetupWizardModel(
            service: service,
            plan: SetupAdvisor.standard.plan(from: ungrouped.applications)
        )
    }

    /// 向导走完（确认或取消都算）之后的收尾：关掉它，并按刚落盘的配置重读一遍。
    public func endSetup() async {
        setup = nil
        await refresh()
    }

    /// 向导被直接关掉：没确认也没取消，那就什么都不写——配置文件仍不存在，
    /// 下次启动还会进向导，这比替用户做一个他没做的决定要诚实。
    public func dismissSetup() {
        setup = nil
    }

    // MARK: - 分组变更

    public func createGroup(named name: String) async {
        var created: Group?
        await perform { created = try $0.createGroup(named: name) }
        // 新建的分组排在列表末尾，把它选中——用户刚建完，下一步多半是往里放应用。
        if let created {
            selection = .group(created.id)
        }
    }

    public func rename(_ groupID: String, to name: String) async {
        await perform { try $0.renameGroup(id: groupID, to: name) }
    }

    /// 请求删除：只记下待确认项，不落盘。真正写入在 `confirmDelete`。
    public func requestDelete(_ groupID: String) {
        pendingDeletion = groups.first { $0.group.id == groupID }
    }

    public func cancelDelete() {
        pendingDeletion = nil
    }

    public func confirmDelete() async {
        guard let pendingDeletion else { return }
        let groupID = pendingDeletion.group.id
        await perform { try $0.deleteGroup(id: groupID) }
        self.pendingDeletion = nil
    }

    /// 拖动分组排序。入参就是 SwiftUI `onMove` 给的那两个。
    public func moveGroups(fromOffsets source: IndexSet, toOffset destination: Int) async {
        guard let from = source.first, groups.indices.contains(from) else { return }
        let groupID = groups[from].group.id
        let index = Self.dropIndex(from: from, toOffset: destination)
        await perform { try $0.moveGroup(id: groupID, toIndex: index) }
    }

    // MARK: - 单个应用

    public func move(_ bundleIdentifier: String, toGroup groupID: String) async {
        await perform { try $0.move(bundleIdentifier: bundleIdentifier, toGroup: groupID) }
    }

    /// 把某个应用拖到组内另一个应用的前面或后面。
    ///
    /// 只给「拖到了哪一行」不够用：那样永远没法把应用放到列表末尾。
    /// 落点在行内偏上就是插到它前面、偏下就是插到它后面，
    /// 与文件管理器里的落点语义一致。
    public func move(_ bundleIdentifier: String, onto targetIdentifier: String, placeAfter: Bool) async {
        guard let groupID = selectedGroupID else { return }
        var order = applications.map(\.bundleIdentifier)
        guard let from = order.firstIndex(of: bundleIdentifier),
              let onto = order.firstIndex(of: targetIdentifier),
              from != onto else { return }

        order.remove(at: from)
        // 被拖的那个取走之后，它后面的元素整体前移一位，目标下标要相应回退。
        let anchor = from < onto ? onto - 1 : onto
        order.insert(bundleIdentifier, at: placeAfter ? anchor + 1 : anchor)
        await perform { try $0.reorder(groupID: groupID, to: order) }
    }

    /// 设置别名；空字符串等同于清除。
    public func setAlias(_ alias: String?, for bundleIdentifier: String) async {
        await perform { try $0.setAlias(alias, for: bundleIdentifier) }
    }

    /// 隐藏或恢复。隐藏只是不在覆盖层露面，应用本身与其余设置都不动。
    public func setHidden(_ hidden: Bool, for bundleIdentifier: String) async {
        await perform { try $0.setHidden(hidden, for: bundleIdentifier) }
    }

    /// 锁定或解锁组内位置。
    public func setLocked(_ locked: Bool, for bundleIdentifier: String) async {
        await perform { try $0.setLocked(locked, for: bundleIdentifier) }
    }

    // MARK: - 开机启动

    /// 开或关开机启动。这里不 `perform`：登录项归系统管，跟配置无关，
    /// 重扫一遍应用纯属浪费。成败都以端口的最新状态回填，不凭乐观假设。
    public func setOpenAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isOpenAtLogin = loginItem.status
    }

    // MARK: - 失效记录

    /// 请求清理：只记下待确认项，不落盘。
    public func requestForget(_ bundleIdentifier: String) {
        pendingForget = missing.first { $0.bundleIdentifier == bundleIdentifier }
    }

    public func cancelForget() {
        pendingForget = nil
    }

    public func confirmForget() async {
        guard let pendingForget else { return }
        let bundleIdentifier = pendingForget.bundleIdentifier
        await perform { try $0.forget(bundleIdentifier: bundleIdentifier) }
        self.pendingForget = nil
    }

    // MARK: - 内部

    /// 跑一次变更，无论成败都重新读一遍快照。
    ///
    /// 失败也刷新是有意的：服务拒绝一次改动时磁盘没动，界面若停在「改过了」的样子
    /// 就是在骗人。重读一遍能保证界面永远显示真正的状态。
    private func perform(_ action: (LibraryService) throws -> Void) async {
        do {
            try action(service)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }

    /// 换上一份已经算好的快照。
    ///
    /// 给「目录监听到变更」这条路用的：那份快照是 `LibrarySync` 扫的，
    /// 这里再扫一遍纯属重复——覆盖层拿到的是同一份快照，两边显示的自然是同一个状态。
    public func apply(_ snapshot: LibrarySnapshot) {
        groups = snapshot.groups
        missing = snapshot.missing

        // 选中的东西没了（分组被删、最后一条失效记录被清理）或还没选过时，落回「未分类」——
        // 右侧永远有确定的内容，不会出现「左边没选中、右边一片空白」。
        if selection == nil || !isAvailable(selection, in: snapshot) {
            selection = snapshot.groups.first { $0.group.isUngrouped }
                .map { .group($0.group.id) }
                ?? snapshot.groups.first.map { .group($0.group.id) }
        }

        // 详情面板跟着列表走：换了分组、或者那条记录被清掉了，原先选中的应用就不该再显示。
        if let selectedApplicationID, !isListed(selectedApplicationID) {
            self.selectedApplicationID = nil
        }
    }

    private func isAvailable(_ selection: ConsoleSelection?, in snapshot: LibrarySnapshot) -> Bool {
        switch selection {
        case .group(let id): snapshot.groups.contains { $0.group.id == id }
        case .missing: !snapshot.missing.isEmpty
        case nil: false
        }
    }

    /// 某个应用在当前这一栏里还找得到吗。
    private func isListed(_ bundleIdentifier: String) -> Bool {
        switch selection {
        case .missing: missing.contains { $0.bundleIdentifier == bundleIdentifier }
        case .group: applications.contains { $0.bundleIdentifier == bundleIdentifier }
        case nil: false
        }
    }

    private func groupName(ofGroup id: String) -> String? {
        groups.first { $0.group.id == id }?.group.name
    }

    /// 把 `onMove` 的落点换算成移除该元素之后的下标。
    ///
    /// `destination` 是「移除之前」的坐标系：往右拖一格时，元素自己占的位置也算在里面，
    /// 所以要先退一格，否则每次右移都会多走一位。
    private static func dropIndex(from source: Int, toOffset destination: Int) -> Int {
        destination > source ? destination - 1 : destination
    }
}
