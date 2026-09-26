import Foundation
import Observation

/// 覆盖层的导航状态：顶层 ↔ 某个分组的子网格。
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

    public init() {}

    /// 展开某个分组的子网格。
    public func open(groupID: String) {
        level = .group(groupID)
    }

    /// 返回上一层。**返回是否消费了这次返回**——已经在顶层就是 false，
    /// 调用方（Esc 与点空白）据此决定要不要接着收起覆盖层。
    @discardableResult
    public func back() -> Bool {
        guard level != .top else { return false }
        level = .top
        return true
    }

    /// 每次唤起都从顶层开始。
    public func reset() {
        level = .top
    }

    /// 换了快照之后对一遍：打开的分组如果没了（在控制台里被删掉），退回顶层。
    ///
    /// 不这么做的话，覆盖层会停在一个「打开着但画不出东西」的状态里，
    /// 用户看到的是一张顶层网格，按 Esc 却要先「返回」一次才收得起来。
    public func reconcile(with snapshot: LibrarySnapshot) {
        guard case .group(let id) = level else { return }
        if !snapshot.groups.contains(where: { $0.group.id == id }) {
            level = .top
        }
    }
}
