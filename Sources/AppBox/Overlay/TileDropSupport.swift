import AppBoxCore
import SwiftUI

/// 两个网格各自的坐标系名字。
///
/// 格子位置与拖拽落点必须在同一个坐标系里量：名字挂在哪个视图上，
/// 落点坐标就以哪个视图为原点——两边只认这一份对齐方式。
enum OverlayDropSpaces {
    static let top = "appbox.overlay.top"
    static let group = "appbox.overlay.group"
}

/// 每个格子在容器里的位置，按格子下标汇总。
///
/// 拖拽判定的一半输入：把落点对到一个格子上、给空白处找最近的邻居，都靠它。
struct TileFramesKey: PreferenceKey {
    static var defaultValue: [Int: Rect] { [:] }

    static func reduce(value: inout [Int: Rect], nextValue: () -> [Int: Rect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 把一个格子的位置报给上面。
///
/// 量的是挂了这个修饰符的那一整块——图标连同名字：落在名字上也就算落在这一格上。
private struct TileFrameReporter: ViewModifier {
    let index: Int
    let space: String

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TileFramesKey.self,
                    value: [index: Rect(proxy.frame(in: .named(space)))]
                )
            }
        }
    }
}

extension View {
    func trackTileFrame(index: Int, space: String) -> some View {
        modifier(TileFrameReporter(index: index, space: space))
    }
}

extension Rect {
    /// SwiftUI 量出来的矩形换算成领域层的矩形。
    init(_ rect: CGRect) {
        self.init(
            origin: Point(x: rect.minX, y: rect.minY),
            size: Size(width: rect.width, height: rect.height)
        )
    }
}

/// 格子内坐标换算到容器坐标。
///
/// 落点判定只认容器坐标：格子自己那份坐标系要先搬回来，才跟量出来的格子位置对得上。
func containerPoint(location: CGPoint, tileIndex: Int, frames: [Int: Rect]) -> Point? {
    guard let frame = frames[tileIndex] else { return nil }
    return Point(x: frame.origin.x + Double(location.x), y: frame.origin.y + Double(location.y))
}

/// 被瞄准的格子该换成谁。
///
/// 「进入」与「离开」送达的先后不保证：只有还指着自己的那次「离开」才清空瞄准，
/// 否则前一个格子的退出事件会把后来者的高亮抹掉。
func dropTargetUpdate(current: Int?, targeted: Bool, index: Int) -> Int? {
    if targeted { return index }
    return current == index ? nil : current
}

/// 一个可拖、可接放的格子。
///
/// 拖动来源按格子种类决定：应用（锁定的除外）拖自己，分组方块拖自己。
/// 接收一律只认应用载荷——分组方块落在格子上是非法落点，判定里会拒绝，
/// 这里连注册都不注册，系统直接不给落。
///
/// 落下时只做一件事：把格子内坐标换算成容器坐标，连同自己的下标交出去。
/// 落点带幽灵守卫（`guardedDropDestination`），Esc 取消后的系统重放不改数据。
struct DroppableTile: View {
    let tile: OverlayTile
    let index: Int
    let isHighlighted: Bool
    let isDropTargeted: Bool
    let space: String
    /// 玻璃形变的命名空间：分组方块展开时要把自己的玻璃交棒给子网格标题。
    var namespace: Namespace.ID? = nil
    let onLaunch: (ApplicationEntry) -> Void
    let onOpenFolder: (String) -> Void
    /// 应用落地：载荷里的 bundleID、格子里量到的落点、自己的下标。
    let onDropApplication: (_ bundleIdentifier: String, _ location: CGPoint, _ index: Int) -> Bool
    let onTargetedChange: (Bool) -> Void

    var body: some View {
        draggableContent.guardedDropDestination(
            for: ApplicationDragPayload.self,
            onTargetedChange: onTargetedChange
        ) { payload, location in
            onDropApplication(payload.bundleIdentifier, location, index)
        }
    }

    /// 拖拽源接线：应用（锁定的除外）拖自己，分组方块拖自己。
    ///
    /// 拖拽源必须收在落点里层。反过来（落点在内、draggable 在外）时，
    /// 同一视图兼作拖拽源与落点会让系统级 Esc 取消被吞掉——拖拽中途按 Esc
    /// 不取消、照样落点（真机探针定位）。所以这里只挂 draggable，
    /// dropDestination 统一在 body 里套到最外。
    @ViewBuilder private var draggableContent: some View {
        let tileView = TileView(
            tile: tile,
            isHighlighted: isHighlighted,
            isDropTargeted: isDropTargeted,
            onLaunch: onLaunch,
            onOpenFolder: onOpenFolder,
            namespace: namespace
        )
        .trackTileFrame(index: index, space: space)

        switch tile {
        case .application(let entry) where entry.isLocked:
            // 锁定的应用不给拖：拖了也不会动，给一个能拖的手感反而是骗人。
            tileView
        case .application(let entry):
            tileView.draggable(ApplicationDragPayload(bundleIdentifier: entry.bundleIdentifier))
        case .folder(let folder):
            tileView.draggable(GroupDragPayload(groupID: folder.id))
        }
    }
}
