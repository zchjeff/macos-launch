import Foundation

/// 覆盖层里被拖着走的东西。
///
/// 两个来源的落点规则完全不同：应用只有落在「这一层摆着的格子」上才有意义，
/// 分组方块只落在空白处。用枚举把来源说清楚，视图按来源挂不同的拖拽载荷类型。
public enum OverlayDragItem: Equatable, Sendable {
    case application(bundleIdentifier: String)
    case folder(groupID: String)
}

/// 一次落点判定该执行的操作。
///
/// 判定算到「哪几个应用按什么顺序」为止，执行交给 `LibraryService` 的既有操作——
/// 覆盖层与控制台因此落的是同一套领域动作，两条 UI 路径不可能产生不一致的结果。
public enum OverlayDropAction: Equatable, Sendable {
    /// 移入某个分组。
    case moveApplication(bundleIdentifier: String, toGroup: String)
    /// 组内重排：数组下标即新的排序权重。
    case reorderApplications(groupID: String, to: [String])
    /// 分组挪到指定位置（移除该分组之后的下标）。
    case moveGroup(id: String, toIndex: Int)
    /// 这个落点不接受——不写盘。
    case rejected
}

/// 拖拽落点的判定。纯函数：一切都由「拖的是什么、落在哪儿、这一层摆着什么」决定，
/// 与 SwiftUI 的事件路由方式无关。
///
/// 摆法这一层有个刻意的选择：**每个落点都独立地按同一份规则算出结果**。
/// 落在格子上还是空白上、由哪一层视图接到这次拖拽，都不影响结论——
/// 视图把落点换算成容器坐标后调用这里，谁接到都一样。
public enum OverlayDrop {
    /// 判定一次拖拽落地该做什么。
    ///
    /// `frames` 是每个格子在自己容器坐标系里的位置，可能比 `tiles` 短：
    /// 网格只铺可见区域，滚出去的格子没有位置可量，也就落不到它上面——
    /// 这正是想要的行为，不是缺陷。
    ///
    /// 拒绝与「落地但无事发生」（比如拖到自己身上）是同一件事：都不写盘。
    public static func action(
        for item: OverlayDragItem,
        at point: Point,
        on level: OverlayModel.Level,
        tiles: [OverlayTile],
        frames: [Int: Rect],
        in snapshot: LibrarySnapshot
    ) -> OverlayDropAction {
        let hit = hitIndex(at: point, tiles: tiles, frames: frames)

        switch item {
        case .application(let bundleIdentifier):
            return applicationAction(
                bundleIdentifier,
                hit: hit, at: point, on: level, tiles: tiles, frames: frames, in: snapshot
            )
        case .folder(let groupID):
            return folderAction(
                groupID,
                hit: hit, at: point, on: level, tiles: tiles, frames: frames, in: snapshot
            )
        }
    }

    // MARK: - 应用

    private static func applicationAction(
        _ bundleIdentifier: String,
        hit: Int?,
        at point: Point,
        on level: OverlayModel.Level,
        tiles: [OverlayTile],
        frames: [Int: Rect],
        in snapshot: LibrarySnapshot
    ) -> OverlayDropAction {
        if let hit, let frame = frames[hit] {
            switch tiles[hit] {
            case .application(let target):
                // 落在另一个应用上 = 组内排序。顶层的应用格子都是「未分类」的，
                // 所以顶层这一路就是把未分类内部排一遍。
                // 落点偏目标的左半边插到它前面，偏右半边插到后面。
                let placeAfter = point.x > frame.midX
                return reorder(
                    bundleIdentifier,
                    onto: target.bundleIdentifier,
                    placeAfter: placeAfter,
                    inGroup: reorderGroupID(of: level),
                    of: snapshot
                )
            case .folder(let folder):
                // 落在分组方块上 = 移入该组。
                return .moveApplication(bundleIdentifier: bundleIdentifier, toGroup: folder.id)
            }
        }

        // 空白：只有子网格里才有定义——把应用放回「未分类」。
        // 顶层的空白不是落点：未分类的应用已经在那儿了，别的来源没有「回未分类」可言。
        guard case .group = level else { return .rejected }
        return .moveApplication(bundleIdentifier: bundleIdentifier, toGroup: Group.ungroupedID)
    }

    /// 排序动作落在哪个分组：顶层是未分类，子网格就是它自己。
    private static func reorderGroupID(of level: OverlayModel.Level) -> String {
        switch level {
        case .top: Group.ungroupedID
        case .group(let id): id
        }
    }

    /// 把「拖到某个应用的前/后」折算成整组的完整顺序与权重。
    ///
    /// 与控制台里的那条路用的是同一套算法（取走被拖的项、目标下标相应回退、
    /// 再按前/后插回），所以同一手势在两个界面里得到同一份结果。
    private static func reorder(
        _ bundleIdentifier: String,
        onto targetIdentifier: String,
        placeAfter: Bool,
        inGroup groupID: String,
        of snapshot: LibrarySnapshot
    ) -> OverlayDropAction {
        guard let order = snapshot.groups
            .first(where: { $0.group.id == groupID })?
            .applications.map(\.bundleIdentifier),
            let from = order.firstIndex(of: bundleIdentifier),
            let onto = order.firstIndex(of: targetIdentifier),
            from != onto
        else { return .rejected }

        var reordered = order
        reordered.remove(at: from)
        // 被拖的那个取走之后，它后面的元素整体前移一位，目标下标要相应回退。
        let anchor = from < onto ? onto - 1 : onto
        reordered.insert(bundleIdentifier, at: placeAfter ? anchor + 1 : anchor)
        return .reorderApplications(groupID: groupID, to: reordered)
    }

    // MARK: - 分组方块

    private static func folderAction(
        _ groupID: String,
        hit: Int?,
        at point: Point,
        on level: OverlayModel.Level,
        tiles: [OverlayTile],
        frames: [Int: Rect],
        in snapshot: LibrarySnapshot
    ) -> OverlayDropAction {
        // 分组方块只落在顶层空白上；落在任何格子——尤其是另一个方块——都拒绝。
        // 原版 Launchpad 里「方块叠方块」是合并分组，这里没有合并，
        // 就不给一个看起来像合并的手势：拒绝比猜用户想干什么诚实。
        guard case .top = level, hit == nil else { return .rejected }

        guard let neighbor = nearestNeighbor(to: point, tiles: tiles, frames: frames) else {
            return .rejected
        }

        let groupIDs = snapshot.groups.map(\.group.id)
        guard let current = groupIDs.firstIndex(of: groupID),
              let neighborIndex = groupIDs.firstIndex(of: groupIDOfTile(tiles[neighbor.index]))
        else { return .rejected }

        // 目标位置是「插到某个分组之前/之后」在移除之前的坐标系里的下标，
        // 而 `moveGroup` 的入参是移除之后的下标——被拖的项排在自己目标前面时，整体回退一位。
        let target = neighbor.placeAfter ? neighborIndex + 1 : neighborIndex
        let index = target > current ? target - 1 : target
        // 落回原位：不写盘。否则一次原地松手也会给整组重新编号。
        guard index != current else { return .rejected }
        return .moveGroup(id: groupID, toIndex: index)
    }

    /// 最近的那个格子，以及落点在它哪一侧（之后 = true）。
    ///
    /// 空白处没有格子可以「落上去」，但插到哪儿总得有个说法：离谁近就插在谁旁边。
    private static func nearestNeighbor(
        to point: Point,
        tiles: [OverlayTile],
        frames: [Int: Rect]
    ) -> (index: Int, placeAfter: Bool)? {
        var nearest: (index: Int, distance: Double)?
        for index in tiles.indices {
            guard let frame = frames[index] else { continue }
            let distance = frame.distance(to: point)
            if nearest == nil || distance < nearest!.distance {
                nearest = (index, distance)
            }
        }
        guard let index = nearest?.index, let frame = frames[index] else { return nil }

        // 格子上方 → 插到它前面；下方 → 后面；同一行左右两侧按中线分。
        let placeAfter: Bool
        if point.y < frame.origin.y {
            placeAfter = false
        } else if point.y > frame.origin.y + frame.size.height {
            placeAfter = true
        } else {
            placeAfter = point.x > frame.midX
        }
        return (index, placeAfter)
    }

    /// 某个顶点所属的分组：顶层的应用格子都属于「未分类」。
    private static func groupIDOfTile(_ tile: OverlayTile) -> String {
        switch tile {
        case .application: Group.ungroupedID
        case .folder(let folder): folder.id
        }
    }

    // MARK: - 几何

    private static func hitIndex(at point: Point, tiles: [OverlayTile], frames: [Int: Rect]) -> Int? {
        tiles.indices.first { frames[$0]?.contains(point) == true }
    }
}

extension LibraryService {
    /// 执行一次落点判定的结果。
    ///
    /// 判定算的是「哪几个应用按什么顺序、去哪个分组」，落盘时走的还是那几个既有操作——
    /// 服务自己该做的校验（分组还在不在、成员是否锁定）一个都不少。
    public func perform(_ action: OverlayDropAction) throws {
        switch action {
        case .moveApplication(let bundleIdentifier, let groupID):
            try move(bundleIdentifier: bundleIdentifier, toGroup: groupID)
        case .reorderApplications(let groupID, let order):
            try reorder(groupID: groupID, to: order)
        case .moveGroup(let id, let index):
            try moveGroup(id: id, toIndex: index)
        case .rejected:
            break
        }
    }
}
