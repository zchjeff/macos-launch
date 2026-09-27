import Foundation
import Testing

@testable import AppBoxCore

/// 格子几何：一行放得下的四个 120×140 的格子，间距 20，起点 (60, 100)。
///
/// 用假坐标而不是真去跑布局：判定只认「格子占哪块地方」，
/// 坐标从哪儿来由视图决定，这里把坐标钉死才能把「各位置组合」一个个说清楚。
private func frames(count: Int) -> [Int: Rect] {
    Dictionary(uniqueKeysWithValues: (0..<count).map { index in
        (
            index,
            Rect(
                origin: Point(x: 60 + Double(index) * 140, y: 100),
                size: Size(width: 120, height: 140)
            )
        )
    })
}

private func p(_ x: Double, _ y: Double) -> Point { Point(x: x, y: y) }

@Suite("覆盖层：拖拽落点判定")
struct OverlayDropTests {
    /// 三层结构：未分类三个应用、开发组两个、工具组一个。
    /// 顶层格子顺序：First、Second、Third（未分类），开发方块，工具方块。
    private func snapshot() -> LibrarySnapshot {
        LibrarySnapshot(groups: [
            GroupSnapshot(group: .ungrouped, applications: [
                TestEntries.make("com.example.first", name: "First"),
                TestEntries.make("com.example.second", name: "Second"),
                TestEntries.make("com.example.third", name: "Third"),
            ]),
            GroupSnapshot(group: Group(id: "dev", name: "开发"), applications: [
                TestEntries.make("com.example.xcode", name: "Xcode"),
                TestEntries.make("com.example.vscode", name: "VS Code"),
            ]),
            GroupSnapshot(group: Group(id: "tools", name: "工具"), applications: [
                TestEntries.make("com.example.calc", name: "Calculator"),
            ]),
        ])
    }

    private func decide(
        _ item: OverlayDragItem,
        at point: Point,
        on level: OverlayModel.Level = .top,
        frames: [Int: Rect],
        in snapshot: LibrarySnapshot
    ) -> OverlayDropAction {
        OverlayDrop.action(
            for: item,
            at: point,
            on: level,
            tiles: level == .top ? snapshot.topLevelTiles : snapshot.tiles(at: level),
            frames: frames,
            in: snapshot
        )
    }

    // MARK: - 应用落在格子上

    @Test("应用拖到分组方块上：移入那一组")
    func applicationOntoFolderMovesIn() {
        let snapshot = snapshot()
        let action = decide(
            .application(bundleIdentifier: "com.example.first"),
            at: p(540, 170),  // 开发方块（下标 3）
            frames: frames(count: 5),
            in: snapshot
        )

        #expect(action == .moveApplication(bundleIdentifier: "com.example.first", toGroup: "dev"))
    }

    @Test("拖到另一个应用的左半边：插到它前面")
    func applicationOntoLeftHalfInsertsBefore() {
        let snapshot = snapshot()
        let action = decide(
            .application(bundleIdentifier: "com.example.third"),
            at: p(80, 170),  // First 的左半边
            frames: frames(count: 5),
            in: snapshot
        )

        #expect(action == .reorderApplications(
            groupID: Group.ungroupedID,
            to: ["com.example.third", "com.example.first", "com.example.second"]
        ))
    }

    @Test("拖到另一个应用的右半边：插到它后面")
    func applicationOntoRightHalfInsertsAfter() {
        let snapshot = snapshot()
        let action = decide(
            .application(bundleIdentifier: "com.example.first"),
            at: p(300, 170),  // Second 的右半边
            frames: frames(count: 5),
            in: snapshot
        )

        #expect(action == .reorderApplications(
            groupID: Group.ungroupedID,
            to: ["com.example.second", "com.example.first", "com.example.third"]
        ))
    }

    @Test("子网格里排序：改动落成这一组的完整顺序")
    func subgridReorderTargetsItsOwnGroup() {
        let snapshot = snapshot()
        let action = decide(
            .application(bundleIdentifier: "com.example.xcode"),
            at: p(300, 170),  // 子网格里 VS Code 的右半边
            on: .group("dev"),
            frames: frames(count: 2),
            in: snapshot
        )

        #expect(action == .reorderApplications(
            groupID: "dev",
            to: ["com.example.vscode", "com.example.xcode"]
        ))
    }

    @Test("组里有隐藏成员时，排的是含隐藏的完整顺序——隐藏的留在自己的位置")
    func reorderUsesFullMemberOrder() {
        // 顺序是 Xcode、隐藏的、VS Code；界面上只看得到 Xcode 与 VS Code。
        let snapshot = LibrarySnapshot(groups: [
            GroupSnapshot(group: Group(id: "dev", name: "开发"), applications: [
                TestEntries.make("com.example.xcode", name: "Xcode"),
                TestEntries.make("com.example.hidden", name: "Hidden", isHidden: true),
                TestEntries.make("com.example.vscode", name: "VS Code"),
            ]),
        ])
        #expect(snapshot.tiles(at: .group("dev")).count == 2)

        let action = decide(
            .application(bundleIdentifier: "com.example.xcode"),
            at: p(300, 170),  // VS Code 的右半边
            on: .group("dev"),
            frames: frames(count: 2),
            in: snapshot
        )

        // 与控制台同算法：Xcode 取走后整队前移，插到 VS Code 之后——隐藏的那个因此前移一格。
        #expect(action == .reorderApplications(
            groupID: "dev",
            to: ["com.example.hidden", "com.example.vscode", "com.example.xcode"]
        ))
    }

    @Test("拖到自己身上：无事发生")
    func droppingOntoItselfIsRejected() {
        let action = decide(
            .application(bundleIdentifier: "com.example.first"),
            at: p(80, 170),  // First 自己
            frames: frames(count: 5),
            in: snapshot()
        )

        #expect(action == .rejected)
    }

    // MARK: - 应用落在空白上

    @Test("子网格空白：移回「未分类」")
    func subgridBlankSendsToUngrouped() {
        let action = decide(
            .application(bundleIdentifier: "com.example.xcode"),
            at: p(500, 500),  // 子网格格子之下
            on: .group("dev"),
            frames: frames(count: 2),
            in: snapshot()
        )

        #expect(action == .moveApplication(
            bundleIdentifier: "com.example.xcode",
            toGroup: Group.ungroupedID
        ))
    }

    @Test("顶层空白：应用没有落点")
    func topBlankRejectsApplications() {
        let action = decide(
            .application(bundleIdentifier: "com.example.first"),
            at: p(500, 500),
            frames: frames(count: 5),
            in: snapshot()
        )

        #expect(action == .rejected)
    }

    // MARK: - 分组方块

    @Test("分组方块叠到另一个方块上：拒绝，不做合并")
    func folderOntoFolderIsRejected() {
        let action = decide(
            .folder(groupID: "dev"),
            at: p(680, 170),  // 工具方块
            frames: frames(count: 5),
            in: snapshot()
        )

        #expect(action == .rejected)
    }

    @Test("分组方块落在应用格子上：拒绝——只认空白")
    func folderOntoApplicationTileIsRejected() {
        let action = decide(
            .folder(groupID: "dev"),
            at: p(80, 170),  // First
            frames: frames(count: 5),
            in: snapshot()
        )

        #expect(action == .rejected)
    }

    @Test("方块落在最前的空白上：排到最前")
    func folderAboveFirstTileMovesToFront() {
        let action = decide(
            .folder(groupID: "dev"),
            at: p(80, 50),  // 第一行之上
            frames: frames(count: 5),
            in: snapshot()
        )

        // 分组顺序 [未分类, dev, tools]：dev 挪到 0 号位。
        #expect(action == .moveGroup(id: "dev", toIndex: 0))
    }

    @Test("方块落在应用块之间的缝里：插到「未分类」之后")
    func folderInGapAfterUngroupedBlock() {
        let action = decide(
            .folder(groupID: "tools"),
            at: p(190, 170),  // Second 与 Third 之间的缝
            frames: frames(count: 5),
            in: snapshot()
        )

        // 分组顺序 [未分类, dev, tools]：tools 插到「未分类」之后 = 移除后的下标 1。
        #expect(action == .moveGroup(id: "tools", toIndex: 1))
    }

    @Test("方块落在末尾空白上：排到最后")
    func folderBelowLastRowMovesToEnd() {
        let action = decide(
            .folder(groupID: "dev"),
            at: p(680, 400),  // 最后一行之下
            frames: frames(count: 5),
            in: snapshot()
        )

        #expect(action == .moveGroup(id: "dev", toIndex: 2))
    }

    @Test("方块落回它已经在的位置：拒绝，不重编号")
    func folderDroppedInPlaceIsRejected() {
        let action = decide(
            .folder(groupID: "dev"),
            at: p(190, 170),  // 「未分类」块之后——正是 dev 现在的位置
            frames: frames(count: 5),
            in: snapshot()
        )

        #expect(action == .rejected)
    }

    @Test("子网格里不存在分组方块：拖进来也无事发生")
    func folderInsideSubgridIsRejected() {
        let action = decide(
            .folder(groupID: "dev"),
            at: p(500, 500),
            on: .group("dev"),
            frames: frames(count: 2),
            in: snapshot()
        )

        #expect(action == .rejected)
    }

    // MARK: - 量不到位置的格子

    @Test("滚出可视区的格子没有位置：命不中它，但最近的邻居照样找得到")
    func partialFramesStillDecide() {
        // 只量到前三个格子（其余滚出去了）。
        let partial = frames(count: 3)

        let ontoMissing = decide(
            .application(bundleIdentifier: "com.example.first"),
            at: p(680, 170),  // 工具方块本该在的位置——没量到
            frames: partial,
            in: snapshot()
        )
        #expect(ontoMissing == .rejected)

        let folder = decide(
            .folder(groupID: "tools"),
            at: p(80, 50),  // 量到的第一个格子之上
            frames: partial,
            in: snapshot()
        )
        #expect(folder == .moveGroup(id: "tools", toIndex: 0))
    }

    @Test("一个格子也没量到：什么也判不出来")
    func noFramesRejectsEverything() {
        #expect(decide(
            .folder(groupID: "dev"), at: p(80, 50), frames: [:], in: snapshot()
        ) == .rejected)
        #expect(decide(
            .application(bundleIdentifier: "com.example.first"),
            at: p(80, 170), frames: [:], in: snapshot()
        ) == .rejected)
    }

    @Test("快照里没有的组、不在组里的应用：拒绝")
    func unknownIdentifiersAreRejected() {
        #expect(decide(
            .folder(groupID: "nope"), at: p(80, 50), frames: frames(count: 5), in: snapshot()
        ) == .rejected)
        #expect(decide(
            .application(bundleIdentifier: "com.example.nope"),
            at: p(80, 170), frames: frames(count: 5), in: snapshot()
        ) == .rejected)
    }
}

@Suite("覆盖层：拖拽结果落盘")
struct OverlayDropApplyTests {
    private func fixture() throws -> ServiceFixture {
        try ServiceFixture(records: [
            TestRecords.make("com.example.first", name: "First"),
            TestRecords.make("com.example.second", name: "Second"),
            TestRecords.make("com.example.third", name: "Third"),
        ], config: AppBoxConfig(groups: [
            .ungrouped,
            Group(id: "dev", name: "开发"),
        ]))
    }

    @Test("移入分组落盘，重启保持")
    func moveIntoGroupPersists() throws {
        let fixture = try fixture()
        let service = fixture.service

        try service.perform(.moveApplication(bundleIdentifier: "com.example.first", toGroup: "dev"))

        let groups = service.snapshot().groups
        #expect(groups.first { $0.group.id == "dev" }?.applications.map(\.bundleIdentifier)
            == ["com.example.first"])
        // 重新读一遍磁盘：上一次改动没真正落盘的话，这里就看不见。
        let reopened = fixture.service.snapshot()
        #expect(reopened.groups.first { $0.group.id == "dev" }?.applications.map(\.bundleIdentifier)
            == ["com.example.first"])
        #expect(reopened.groups.first { $0.group.isUngrouped }?.applications.map(\.bundleIdentifier)
            == ["com.example.second", "com.example.third"])
    }

    @Test("拒绝：一个字节都不写")
    func rejectedWritesNothing() throws {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.first", name: "First"),
        ])
        let service = fixture.service

        try service.perform(.rejected)

        #expect(service.currentConfig.applications.isEmpty)
    }

    @Test("同一手势在覆盖层与控制台得到同一份结果")
    @MainActor
    func overlayMatchesConsole() async throws {
        // 控制台：把 First 拖到 Third 的下半区。
        let consoleFixture = try fixture()
        let model = ConsoleModel(service: consoleFixture.service)
        await model.refresh()
        await model.move("com.example.first", onto: "com.example.third", placeAfter: true)
        let consoleOrder = model.applications.map(\.bundleIdentifier)

        // 覆盖层：同样的手势——把 First 拖到 Third 的右半边。
        let overlayFixture = try fixture()
        let service = overlayFixture.service
        let snapshot = service.snapshot()
        let action = OverlayDrop.action(
            for: .application(bundleIdentifier: "com.example.first"),
            at: p(420, 170),  // Third（第三个格子）的右半边
            on: .top,
            tiles: snapshot.topLevelTiles,
            frames: frames(count: 3),  // 开发方块滚在屏外，量不到位置
            in: snapshot
        )
        try service.perform(action)

        let overlayOrder = service.snapshot()
            .groups.first { $0.group.isUngrouped }?
            .applications.map(\.bundleIdentifier)
        #expect(overlayOrder == consoleOrder)
        #expect(overlayOrder == ["com.example.second", "com.example.third", "com.example.first"])
    }
}
