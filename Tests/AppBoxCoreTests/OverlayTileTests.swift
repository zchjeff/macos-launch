import Foundation
import Testing

@testable import AppBoxCore

@Suite("覆盖层顶层：格子投影")
struct OverlayTileTests {
    private func group(_ id: String, _ name: String, _ applications: [ApplicationEntry]) -> GroupSnapshot {
        GroupSnapshot(group: Group(id: id, name: name), applications: applications)
    }

    private func applications(_ count: Int, prefix: String = "com.example.app") -> [ApplicationEntry] {
        (0..<count).map { TestEntries.make("\(prefix)\($0)", name: "App\($0)") }
    }

    @Test("未分组的应用铺成单图标，其余分组各占一个文件夹方块")
    func ungroupedAppsBecomeLooseTiles() {
        let snapshot = LibrarySnapshot(groups: [
            group(Group.ungroupedID, "未分类", applications(2, prefix: "com.example.loose")),
            group("dev", "开发工具", applications(3, prefix: "com.example.dev")),
        ])

        let tiles = snapshot.topLevelTiles

        guard case .application(let first) = tiles[0],
              case .application(let second) = tiles[1],
              case .folder(let folder) = tiles[2] else {
            Issue.record("顶层格子应当是「两个单图标 + 一个方块」，实际是 \(tiles)")
            return
        }
        #expect(first.bundleIdentifier == "com.example.loose0")
        #expect(second.bundleIdentifier == "com.example.loose1")
        #expect(folder.name == "开发工具")
        #expect(folder.thumbnails.map(\.bundleIdentifier) == ["com.example.dev0", "com.example.dev1", "com.example.dev2"])
        #expect(tiles.count == 3)
    }

    @Test("未分类自己永远不是方块——它已经被铺开了")
    func ungroupedGroupNeverBecomesAFolder() {
        let snapshot = LibrarySnapshot(groups: [group(Group.ungroupedID, "未分类", applications(1))])

        #expect(snapshot.topLevelTiles.count == 1)
        for tile in snapshot.topLevelTiles {
            if case .folder = tile { Issue.record("未分类不该出方块") }
        }
    }

    @Test("分组顺序即展示顺序")
    func tilesFollowGroupOrder() {
        let snapshot = LibrarySnapshot(groups: [
            group(Group.ungroupedID, "未分类", []),
            group("b", "第二个", applications(1, prefix: "com.example.b")),
            group("a", "第一个", applications(1, prefix: "com.example.a")),
        ])

        #expect(snapshot.topLevelTiles.map(\.displayName) == ["第二个", "第一个"])
    }

    @Test("缩略图标最多 9 个：0/1/8/9/10/50 都按实际数量与上限来", arguments: [0, 1, 8, 9, 10, 50])
    func thumbnailsAreCappedAtNine(count: Int) {
        let snapshot = LibrarySnapshot(groups: [
            group(Group.ungroupedID, "未分类", []),
            group("dev", "开发工具", applications(count)),
        ])

        let folder = snapshot.topLevelTiles.compactMap { tile -> FolderTile? in
            if case .folder(let folder) = tile { return folder }
            return nil
        }.first

        #expect(folder?.thumbnails.count == min(count, 9))
        // 取的是组内靠前的那些，顺序原样。
        #expect(folder?.thumbnails.map(\.displayName) == (0..<min(count, 9)).map { "App\($0)" })
    }

    @Test("空分组照样有方块")
    func emptyGroupStillGetsAFolder() {
        let snapshot = LibrarySnapshot(groups: [
            group(Group.ungroupedID, "未分类", []),
            group("empty", "空组", []),
        ])

        guard case .folder(let folder) = snapshot.topLevelTiles.first else {
            Issue.record("空分组也该出方块")
            return
        }
        #expect(folder.name == "空组")
        #expect(folder.thumbnails.isEmpty)
    }

    @Test("隐藏的应用既不上顶层，也不进缩略图标")
    func hiddenApplicationsStayOut() {
        let snapshot = LibrarySnapshot(groups: [
            group(Group.ungroupedID, "未分类", [
                TestEntries.make("com.example.loose", name: "可见"),
                TestEntries.make("com.example.hidden", name: "藏起来了", isHidden: true),
            ]),
            group("dev", "开发工具", [
                TestEntries.make("com.example.dev", name: "可见"),
                TestEntries.make("com.example.shownot", name: "藏起来了", isHidden: true),
            ]),
        ])

        let names = snapshot.topLevelTiles.map(\.displayName)
        #expect(names == ["可见", "开发工具"])

        guard case .folder(let folder) = snapshot.topLevelTiles.last else {
            Issue.record("开发工具该是方块")
            return
        }
        #expect(folder.thumbnails.map(\.displayName) == ["可见"])
    }

    @Test("组里只剩隐藏应用时，方块还在、缩略图标为空")
    func folderWithOnlyHiddenApplicationsKeepsTheTile() {
        let snapshot = LibrarySnapshot(groups: [
            group(Group.ungroupedID, "未分类", []),
            group("dev", "开发工具", [TestEntries.make("com.example.dev", name: "藏起来了", isHidden: true)]),
        ])

        guard case .folder(let folder) = snapshot.topLevelTiles.first else {
            Issue.record("方块不该因为组里全是隐藏应用就消失")
            return
        }
        #expect(folder.thumbnails.isEmpty)
    }
}

@MainActor
@Suite("覆盖层：顶层与子网格的导航")
struct OverlayModelTests {
    @Test("刚建出来在顶层")
    func startsAtTop() {
        #expect(OverlayModel().level == .top)
    }

    @Test("展开一个分组后进子网格")
    func opensGroup() {
        let model = OverlayModel()

        model.open(groupID: "dev")

        #expect(model.level == .group("dev"))
    }

    @Test("子网格里返回：回顶层，并说明这次返回被消费掉了")
    func backsOutOfAGroup() {
        let model = OverlayModel()
        model.open(groupID: "dev")

        #expect(model.back() == true)
        #expect(model.level == .top)
    }

    @Test("已经在顶层再返回：不消费——Esc 这时候才轮到收起覆盖层")
    func backAtTopIsNotConsumed() {
        let model = OverlayModel()

        #expect(model.back() == false)
        #expect(model.level == .top)
    }

    @Test("每次唤起都从顶层开始")
    func resetsOnShow() {
        let model = OverlayModel()
        model.open(groupID: "dev")

        model.reset()

        #expect(model.level == .top)
    }

    @Test("打开的分组在快照里没了（比如在控制台里删掉）就退回顶层")
    func reconcilesWithSnapshot() {
        let model = OverlayModel()
        model.open(groupID: "dev")
        let snapshot = LibrarySnapshot(groups: [
            GroupSnapshot(group: .ungrouped, applications: []),
        ])

        model.reconcile(with: snapshot)

        #expect(model.level == .top)
    }

    @Test("分组还在就不动它——后台刷新不该把用户踢出子网格")
    func keepsOpenGroupThatStillExists() {
        let model = OverlayModel()
        model.open(groupID: "dev")
        let snapshot = LibrarySnapshot(groups: [
            GroupSnapshot(group: .ungrouped, applications: []),
            GroupSnapshot(group: Group(id: "dev", name: "开发工具"), applications: []),
        ])

        model.reconcile(with: snapshot)

        #expect(model.level == .group("dev"))
    }
}
