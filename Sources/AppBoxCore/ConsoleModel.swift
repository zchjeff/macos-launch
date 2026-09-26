import Foundation
import Observation

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
    /// 当前选中的分组。界面直接双向绑定。
    public var selectedGroupID: String?
    /// 待确认的删除。界面据此弹确认框——**确认之前一个字节都不写**。
    public var pendingDeletion: GroupSnapshot?
    /// 最近一次失败的说法。nil 表示没有未处理的错误。
    public private(set) var errorMessage: String?
    /// 首轮加载中（冷扫描要几百毫秒，界面得有点表示）。
    public private(set) var isLoading = false

    private let service: LibraryService

    public init(service: LibraryService) {
        self.service = service
    }

    // MARK: - 读

    /// 选中分组里的应用，顺序就是界面上的顺序。
    public var applications: [ApplicationEntry] {
        groups.first { $0.group.id == selectedGroupID }?.applications ?? []
    }

    public var selectedGroup: Group? {
        groups.first { $0.group.id == selectedGroupID }?.group
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

    // MARK: - 同步

    /// 重新读一遍分组结构。
    ///
    /// 扫描是阻塞的（冷启动近半秒），所以放到主线程外做，回主线程再赋值——
    /// 否则控制台一打开就整窗卡住。
    public func refresh() async {
        isLoading = true
        let service = self.service
        let snapshot = await Task.detached(priority: .userInitiated) { service.snapshot() }.value
        isLoading = false
        apply(snapshot)
    }

    public func dismissError() {
        errorMessage = nil
    }

    // MARK: - 分组变更

    public func createGroup(named name: String) async {
        var created: Group?
        await perform { created = try $0.createGroup(named: name) }
        // 新建的分组排在列表末尾，把它选中——用户刚建完，下一步多半是往里放应用。
        if let created {
            selectedGroupID = created.id
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

    // MARK: - 应用归属与顺序

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

    private func apply(_ snapshot: LibrarySnapshot) {
        groups = snapshot.groups

        // 选中的分组没了（被删掉）或还没选过时，落到「未分类」——
        // 右侧永远有确定的内容，不会出现「左边没选中、右边一片空白」。
        let stillExists = snapshot.groups.contains { $0.group.id == selectedGroupID }
        if !stillExists {
            selectedGroupID = snapshot.groups.first { $0.group.isUngrouped }?.group.id
                ?? snapshot.groups.first?.group.id
        }
    }

    /// 把 `onMove` 的落点换算成移除该元素之后的下标。
    ///
    /// `destination` 是「移除之前」的坐标系：往右拖一格时，元素自己占的位置也算在里面，
    /// 所以要先退一格，否则每次右移都会多走一位。
    private static func dropIndex(from source: Int, toOffset destination: Int) -> Int {
        destination > source ? destination - 1 : destination
    }
}
