import Foundation
import Testing

@testable import AppBoxCore

@Suite("覆盖层键盘：网格移动")
struct GridNavigationTests {
    @Test("手算的几组位置：左右一行内挪、上下跨行、到边停住")
    func handComputedPositions() {
        // 7 列、10 项：第一行 0…6，第二行 7…9（末行不满）。
        let count = 10
        let columns = 7
        func move(_ index: Int, _ direction: GridDirection) -> Int {
            GridNavigation.destination(from: index, direction: direction, count: count, columns: columns)
        }

        #expect(move(3, .left) == 2)
        #expect(move(3, .right) == 4)
        #expect(move(3, .up) == 3)      // 第一行，到顶停住
        #expect(move(3, .down) == 3)    // 3+7=10 不比 10 小，停住
        #expect(move(0, .left) == 0)
        #expect(move(6, .right) == 6)   // 行尾
        #expect(move(0, .down) == 7)
        #expect(move(2, .down) == 9)    // 末行不满也够得着
        #expect(move(8, .up) == 1)
        #expect(move(9, .left) == 8)
        #expect(move(9, .right) == 9)   // 最后一项
    }

    @Test("列数 1 到 12：左右不跨行、上下不换列", arguments: 1...12)
    func directionStaysOnItsAxis(columns: Int) {
        let count = 40
        for index in 0..<count {
            let row = index / columns
            let column = index % columns

            let left = GridNavigation.destination(from: index, direction: .left, count: count, columns: columns)
            let right = GridNavigation.destination(from: index, direction: .right, count: count, columns: columns)
            let up = GridNavigation.destination(from: index, direction: .up, count: count, columns: columns)
            let down = GridNavigation.destination(from: index, direction: .down, count: count, columns: columns)

            #expect(left / columns == row, "左不该跨行")
            #expect(right / columns == row, "右不该跨行")
            #expect(up % columns == column, "上不该换列")
            #expect(down % columns == column, "下不该换列")
            // 到边停住而不是回绕：一次只挪一格（左右）或一行（上下）。
            #expect(abs(left - index) <= 1)
            #expect(abs(right - index) <= 1)
            #expect(abs(up - index) == 0 || abs(up - index) == columns)
            #expect(abs(down - index) == 0 || abs(down - index) == columns)
        }
    }

    @Test("每项都点得到：从第一个图标出发只用方向键能走到每一项", arguments: [2, 5, 9, 22, 60, 100])
    func everyTileIsReachable(count: Int) {
        let columns = OverlayGrid.columns
        var reached: Set<Int> = [0]
        var queue = [0]
        while let index = queue.popLast() {
            for direction in GridDirection.allCases {
                let next = GridNavigation.destination(from: index, direction: direction, count: count, columns: columns)
                if reached.insert(next).inserted { queue.append(next) }
            }
        }

        #expect(reached.count == count)
    }

    @Test("只有一两项、末行不满时，边界移动不越界", arguments: [1, 2, 3])
    func neverEscapesBounds(count: Int) {
        for columns in 1...12 {
            for index in 0..<count {
                for direction in GridDirection.allCases {
                    let result = GridNavigation.destination(from: index, direction: direction, count: count, columns: columns)
                    #expect(result >= 0 && result < count, "count=\(count) columns=\(columns) index=\(index)")
                }
            }
        }
    }

    @Test("空网格没有可挪的项")
    func emptyGridStaysPut() {
        for direction in GridDirection.allCases {
            #expect(GridNavigation.destination(from: 0, direction: direction, count: 0, columns: 7) == 0)
        }
    }

    @Test("高亮越界了先夹回范围再算")
    func outOfRangeIndexIsClampedFirst() {
        #expect(GridNavigation.destination(from: 99, direction: .right, count: 5, columns: 7) == 4)
        #expect(GridNavigation.destination(from: -3, direction: .right, count: 5, columns: 7) == 1)
    }
}

@MainActor
@Suite("覆盖层：键盘高亮")
struct OverlaySelectionTests {
    private func tiles(_ names: [String]) -> [OverlayTile] {
        names.map { .application(TestEntries.make("com.example.\($0)", name: $0)) }
    }

    private func snapshot(_ names: [String]) -> LibrarySnapshot {
        LibrarySnapshot(groups: [
            GroupSnapshot(
                group: .ungrouped,
                applications: names.map { TestEntries.make("com.example.\($0)", name: $0) }
            ),
        ])
    }

    @Test("某一层的格子：顶层是方块与单图标，子网格是该组自己的应用")
    func tilesAtLevel() {
        let snapshot = LibrarySnapshot(groups: [
            GroupSnapshot(group: .ungrouped, applications: [TestEntries.make("com.example.loose", name: "散装")]),
            GroupSnapshot(
                group: Group(id: "dev", name: "开发工具"),
                applications: [
                    TestEntries.make("com.example.a", name: "A"),
                    TestEntries.make("com.example.b", name: "B"),
                ]
            ),
        ])

        #expect(snapshot.tiles(at: .top).map(\.displayName) == ["散装", "开发工具"])
        #expect(snapshot.tiles(at: .group("dev")).map(\.displayName) == ["A", "B"])
        #expect(snapshot.tiles(at: .group("没了")).isEmpty)
    }

    @Test("刚建出来高亮在第一个图标上")
    func startsOnTheFirstTile() {
        #expect(OverlayModel().selection == 0)
    }

    @Test("方向键挪高亮：左右一格、上下一行")
    func movesByGridGeometry() {
        let model = OverlayModel()
        let items = tiles((0..<10).map { "App\($0)" })

        model.move(.right, columns: 7, in: items)
        #expect(model.selection == 1)
        model.move(.down, columns: 7, in: items)
        #expect(model.selection == 8)
        model.move(.left, columns: 7, in: items)
        #expect(model.selection == 7)
        model.move(.up, columns: 7, in: items)
        #expect(model.selection == 0)
    }

    @Test("进子网格高亮从第一个开始，返回后还在原来那个方块上")
    func remembersTopSelectionAcrossASubgrid() {
        let model = OverlayModel()
        let top = tiles(["A", "B", "C", "D"])
        model.move(.right, columns: 7, in: top)
        model.move(.right, columns: 7, in: top)
        #expect(model.selection == 2)

        model.open(groupID: "dev")
        #expect(model.selection == 0)
        model.move(.right, columns: 7, in: tiles(["x", "y"]))
        #expect(model.selection == 1)

        #expect(model.back() == true)
        #expect(model.selection == 2)
    }

    @Test("每次唤起都忘了上次的高亮")
    func resetForgetsBothLevels() {
        let model = OverlayModel()
        model.move(.right, columns: 7, in: tiles(["a", "b", "c"]))
        model.open(groupID: "dev")
        model.reset()

        #expect(model.level == .top)
        #expect(model.selection == 0)

        // 记住的那份也归零了：再进出一次子网格，高亮该在第一个，而不是重置前的 1。
        model.open(groupID: "dev")
        model.back()
        #expect(model.selection == 0)
    }

    @Test("快照变小了，高亮夹回能点到的范围")
    func clampsWhenSnapshotShrinks() {
        let model = OverlayModel()
        let items = tiles(["A", "B", "C", "D", "E"])
        for _ in 0..<3 { model.move(.right, columns: 7, in: items) }
        #expect(model.selection == 3)

        model.reconcile(with: snapshot(["A", "B"]))

        #expect(model.selection == 1)
    }

    @Test("空分组：没有高亮项，挪动与回车都不做事")
    func emptyGroupHasNothingToMoveTo() {
        let model = OverlayModel()
        model.open(groupID: "empty")
        model.reconcile(with: LibrarySnapshot(groups: [
            GroupSnapshot(group: .ungrouped, applications: []),
            GroupSnapshot(group: Group(id: "empty", name: "空组"), applications: []),
        ]))

        for direction in GridDirection.allCases {
            model.move(direction, columns: 7, in: [])
        }

        #expect(model.selection == 0)
        #expect(model.activation(in: []) == nil)
    }

    @Test("回车：单图标给「启动」，方块给「展开」")
    func activationMatchesTheTile() {
        let model = OverlayModel()
        let entry = TestEntries.make("com.example.solo", name: "Solo")
        let folder = FolderTile(
            group: GroupSnapshot(group: Group(id: "dev", name: "开发工具"), applications: [])
        )
        let items: [OverlayTile] = [.application(entry), .folder(folder)]

        #expect(model.activation(in: items) == .launch(entry))
        model.move(.right, columns: 7, in: items)
        #expect(model.activation(in: items) == .openGroup("dev"))
    }
}
