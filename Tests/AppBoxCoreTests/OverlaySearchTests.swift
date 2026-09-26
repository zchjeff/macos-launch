import Foundation
import Testing

@testable import AppBoxCore

@MainActor
@Suite("覆盖层：搜索状态")
struct OverlaySearchTests {
    private func snapshot(_ names: [String]) -> LibrarySnapshot {
        LibrarySnapshot(groups: [
            GroupSnapshot(
                group: .ungrouped,
                applications: names.map { TestEntries.make("com.example.\($0)", name: $0) }
            ),
        ])
    }

    @Test("刚建出来没在搜索，格子还是当前那一份")
    func notSearchingInitially() {
        let model = OverlayModel()
        #expect(!model.isSearching)
        #expect(model.query.isEmpty)
        #expect(model.searchResults.isEmpty)
        #expect(model.tiles(in: snapshot(["Alpha", "Beta"])).map(\.displayName) == ["Alpha", "Beta"])
    }

    @Test("输入字符进入搜索：结果过滤、高亮回到第一个、tiles 换成结果")
    func typingEntersSearch() {
        let model = OverlayModel()
        let snapshot = snapshot(["Alpha", "Beta", "Alpaca"])

        model.type("a")
        model.updateSearch(in: snapshot)

        #expect(model.isSearching)
        #expect(model.query == "a")
        #expect(model.searchResults.map(\.displayName) == ["Alpaca", "Alpha"])
        #expect(model.selection == 0)
        #expect(model.tiles(in: snapshot).map(\.displayName) == ["Alpaca", "Alpha"])
    }

    @Test("继续输入收窄，退格一格又变宽")
    func typingNarrowsAndBackspaceWidens() {
        let model = OverlayModel()
        let snapshot = snapshot(["Alpha", "Alpaca"])

        model.type("alp")
        model.updateSearch(in: snapshot)
        // `alp` 是两者的共同前缀，此刻还分不出来。
        #expect(model.searchResults.map(\.displayName) == ["Alpaca", "Alpha"])

        model.type("a")
        model.updateSearch(in: snapshot)
        #expect(model.searchResults.map(\.displayName) == ["Alpaca"])

        model.deleteLastQueryCharacter()
        model.updateSearch(in: snapshot)
        #expect(model.query == "alp")
        #expect(model.searchResults.map(\.displayName) == ["Alpaca", "Alpha"])
    }

    @Test("删到空：回到原来那一层，高亮复原到搜索前的位置")
    func clearingReturnsToTheLevel() {
        let model = OverlayModel()
        let snapshot = snapshot(["Alpha", "Beta", "Gamma"])
        model.move(.right, columns: 7, in: model.tiles(in: snapshot))
        #expect(model.selection == 1)

        model.type("a")
        model.updateSearch(in: snapshot)
        #expect(model.selection == 0)

        model.clearSearch()
        model.updateSearch(in: snapshot)

        #expect(!model.isSearching)
        #expect(model.query.isEmpty)
        #expect(model.selection == 1)
        #expect(model.tiles(in: snapshot).map(\.displayName) == ["Alpha", "Beta", "Gamma"])
    }

    @Test("搜索里方向键在结果内挪，回车给「启动」")
    func arrowsAndEnterInsideResults() {
        let model = OverlayModel()
        let snapshot = snapshot(["Alpha", "Alpaca", "Beta"])
        model.type("al")
        model.updateSearch(in: snapshot)
        let results = model.searchResults
        #expect(results.map(\.displayName) == ["Alpaca", "Alpha"])

        #expect(model.activation(in: model.tiles(in: snapshot)) == .launch(results[0]))

        model.move(.right, columns: 7, in: model.tiles(in: snapshot))
        #expect(model.selection == 1)
        #expect(model.activation(in: model.tiles(in: snapshot)) == .launch(results[1]))
    }

    @Test("结果为空：没有可点项，回车与方向键都不出事")
    func emptyResultsHaveNothingToActivate() {
        let model = OverlayModel()
        let snapshot = snapshot(["Alpha"])
        model.type("zzz")
        model.updateSearch(in: snapshot)

        #expect(model.isSearching)
        #expect(model.searchResults.isEmpty)
        #expect(model.tiles(in: snapshot).isEmpty)
        #expect(model.activation(in: model.tiles(in: snapshot)) == nil)
        for direction in GridDirection.allCases {
            model.move(direction, columns: 7, in: model.tiles(in: snapshot))
        }
        #expect(model.selection == 0)
    }

    @Test("快照变了：结果跟着重算，高亮夹回范围")
    func reconcileRefreshesResults() {
        let model = OverlayModel()
        model.type("al")
        model.updateSearch(in: snapshot(["Alpha", "Alpaca"]))
        model.move(.right, columns: 7, in: model.tiles(in: snapshot(["Alpha", "Alpaca"])))
        #expect(model.selection == 1)

        model.reconcile(with: snapshot(["Alpha"]))

        #expect(model.searchResults.map(\.displayName) == ["Alpha"])
        #expect(model.selection == 0)
    }

    @Test("在子网格里搜：范围仍是全库，清空后回到那个子网格")
    func searchFromASubgridIsGlobal() {
        let model = OverlayModel()
        let snapshot = LibrarySnapshot(groups: [
            GroupSnapshot(group: .ungrouped, applications: [TestEntries.make("com.example.loose", name: "Loose")]),
            GroupSnapshot(group: Group(id: "dev", name: "开发工具"), applications: [
                TestEntries.make("com.example.alpha", name: "Alpha"),
                TestEntries.make("com.example.beta", name: "Beta"),
            ]),
        ])

        model.open(groupID: "dev")
        model.move(.right, columns: 7, in: model.tiles(in: snapshot))
        #expect(model.selection == 1)

        model.type("l")
        model.updateSearch(in: snapshot)
        #expect(model.searchResults.map(\.displayName) == ["Loose"])

        model.clearSearch()
        model.updateSearch(in: snapshot)
        #expect(model.level == .group("dev"))
        #expect(model.selection == 1)
        #expect(model.tiles(in: snapshot).map(\.displayName) == ["Alpha", "Beta"])
    }

    @Test("每次唤起都把上次的搜索忘干净")
    func resetClearsSearch() {
        let model = OverlayModel()
        model.type("a")
        model.updateSearch(in: snapshot(["Alpha"]))
        model.reset()

        #expect(!model.isSearching)
        #expect(model.query.isEmpty)
        #expect(model.searchResults.isEmpty)
        #expect(model.selection == 0)
    }
}
