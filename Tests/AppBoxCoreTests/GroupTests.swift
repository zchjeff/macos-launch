import Foundation
import Testing

@testable import AppBoxCore

@Suite("分组的增删改")
struct GroupMutationTests {
    @Test("新建的分组排在已有分组之后")
    func createsGroupAtTheEnd() throws {
        let subject = try ServiceFixture().service

        let first = try subject.createGroup(named: "开发")
        let second = try subject.createGroup(named: "游戏")

        #expect(subject.currentConfig.groups.map(\.id) == [Group.ungroupedID, first.id, second.id])
        #expect(subject.currentConfig.groups.map(\.name) == ["未分类", "开发", "游戏"])
    }

    @Test("分组名首尾空白被裁掉，空名字被拒绝")
    func validatesGroupName() throws {
        let subject = try ServiceFixture().service

        #expect(try subject.createGroup(named: "  开发  ").name == "开发")
        #expect(throws: GroupError.emptyName) { try subject.createGroup(named: "   ") }
    }

    @Test("重命名分组")
    func renamesGroup() throws {
        let subject = try ServiceFixture().service
        let group = try subject.createGroup(named: "开发")

        try subject.renameGroup(id: group.id, to: "编程")

        #expect(subject.currentConfig.groups.map(\.name) == ["未分类", "编程"])
    }

    @Test("重命名不存在的分组报错")
    func renamingMissingGroupFails() throws {
        let subject = try ServiceFixture().service

        #expect(throws: GroupError.groupNotFound("nope")) {
            try subject.renameGroup(id: "nope", to: "无所谓")
        }
    }

    @Test("改动落盘，重启后还在")
    func mutationsSurviveRestart() throws {
        let fixture = try ServiceFixture()
        let created = try fixture.service.createGroup(named: "开发")
        try fixture.service.renameGroup(id: created.id, to: "编程")

        let names = fixture.service.currentConfig.groups.map(\.name)

        #expect(names == ["未分类", "编程"])
    }
}

@Suite("「未分类」保护")
struct UngroupedProtectionTests {
    @Test("「未分类」不可删除")
    func cannotDeleteUngrouped() throws {
        let subject = try ServiceFixture().service

        #expect(throws: GroupError.ungroupedIsProtected) {
            try subject.deleteGroup(id: Group.ungroupedID)
        }
        #expect(subject.currentConfig.groups.contains { $0.isUngrouped })
    }

    @Test("「未分类」不可重命名")
    func cannotRenameUngrouped() throws {
        let subject = try ServiceFixture().service

        #expect(throws: GroupError.ungroupedIsProtected) {
            try subject.renameGroup(id: Group.ungroupedID, to: "别的名字")
        }
        #expect(subject.currentConfig.groups.map(\.name) == ["未分类"])
    }

    @Test("配置里没有「未分类」时，读出来会补回去")
    func restoresMissingUngrouped() throws {
        // 手改配置文件把「未分类」删掉了——ADR-0005 允许手改，那就得兜住。
        let fixture = try ServiceFixture(config: AppBoxConfig(groups: [Group(id: "dev", name: "开发")]))

        #expect(fixture.service.currentConfig.groups.map(\.id) == [Group.ungroupedID, "dev"])
    }

    @Test("归属指向已消失分组的应用落回「未分类」，而不是消失")
    func repointsOrphanedApplications() throws {
        let config = AppBoxConfig(
            groups: [.ungrouped],
            applications: ["com.example.app": ApplicationConfig(groupID: "已经没了的组")]
        )
        let fixture = try ServiceFixture(
            records: [TestRecords.make("com.example.app", name: "App")],
            config: config
        )

        let snapshot = fixture.service.snapshot()

        #expect(snapshot.allApplications.map(\.bundleIdentifier) == ["com.example.app"])
        #expect(snapshot.groups.first { $0.group.isUngrouped }?.applications.count == 1)
    }
}

@Suite("删除分组与应用的落点")
struct GroupDeletionTests {
    private func configWithGroup() -> AppBoxConfig {
        AppBoxConfig(
            groups: [.ungrouped, Group(id: "dev", name: "开发")],
            applications: [
                "com.example.first": ApplicationConfig(groupID: "dev", orderWeight: 3),
                "com.example.second": ApplicationConfig(groupID: "dev"),
            ]
        )
    }

    private func records() -> [AppRecord] {
        [
            TestRecords.make("com.example.first", name: "First"),
            TestRecords.make("com.example.second", name: "Second"),
        ]
    }

    @Test("删掉分组后，组内应用全部落回「未分类」，一个都不丢")
    func deletionMovesApplicationsToUngrouped() throws {
        let fixture = try ServiceFixture(records: records(), config: configWithGroup())
        let subject = fixture.service

        try subject.deleteGroup(id: "dev")

        let snapshot = subject.snapshot()
        #expect(subject.currentConfig.groups.map(\.id) == [Group.ungroupedID])
        let ungrouped = try #require(snapshot.groups.first { $0.group.isUngrouped })
        // 这里只关心「一个都没丢」，顺序由权重决定、另有测试覆盖。
        #expect(Set(ungrouped.applications.map(\.bundleIdentifier))
            == ["com.example.first", "com.example.second"])
        #expect(snapshot.allApplications.count == 2)
    }

    @Test("删除分组只改归属，应用的排序权重保留")
    func deletionKeepsOtherApplicationSettings() throws {
        let fixture = try ServiceFixture(records: records(), config: configWithGroup())
        let subject = fixture.service

        try subject.deleteGroup(id: "dev")

        let application = try #require(subject.currentConfig.applications["com.example.first"])
        #expect(application.groupID == Group.ungroupedID)
        #expect(application.orderWeight == 3)
    }

    @Test("删除分组后落盘，重启后组内应用仍在「未分类」")
    func deletionIsPersisted() throws {
        let fixture = try ServiceFixture(records: records(), config: configWithGroup())
        try fixture.service.deleteGroup(id: "dev")

        let reloaded = fixture.service
        let ungrouped = try #require(reloaded.snapshot().groups.first { $0.group.isUngrouped })

        #expect(ungrouped.applications.count == 2)
    }

    @Test("空分组保留，不自动删除")
    func emptyGroupsAreKept() throws {
        let subject = try ServiceFixture().service
        let group = try subject.createGroup(named: "空组")

        let snapshot = subject.snapshot()
        let empty = try #require(snapshot.groups.first { $0.group.id == group.id })

        #expect(empty.applications.isEmpty)
        #expect(subject.currentConfig.groups.contains { $0.id == group.id })
    }
}

@Suite("应用归属与分组顺序")
struct GroupArrangementTests {
    private func records() -> [AppRecord] {
        [
            TestRecords.make("com.example.first", name: "First"),
            TestRecords.make("com.example.second", name: "Second"),
        ]
    }

    @Test("应用移入分组后只出现在那一组，不再出现在「未分类」")
    func movingApplicationKeepsSingleMembership() throws {
        let fixture = try ServiceFixture(records: records())
        let subject = fixture.service
        let group = try subject.createGroup(named: "开发")

        try subject.move(bundleIdentifier: "com.example.first", toGroup: group.id)

        let snapshot = subject.snapshot()
        #expect(snapshot.groups.first { $0.group.id == group.id }?.applications.map(\.bundleIdentifier)
            == ["com.example.first"])
        #expect(snapshot.groups.first { $0.group.isUngrouped }?.applications.map(\.bundleIdentifier)
            == ["com.example.second"])
        #expect(snapshot.allApplications.count == 2)
    }

    @Test("移到不存在的分组被拒绝")
    func movingToMissingGroupFails() throws {
        let fixture = try ServiceFixture(records: records())
        let subject = fixture.service

        #expect(throws: GroupError.groupNotFound("nope")) {
            try subject.move(bundleIdentifier: "com.example.first", toGroup: "nope")
        }
    }

    @Test("配置里还没有该应用时，移动会顺带建一条记录")
    func movingUnrecordedApplicationCreatesEntry() throws {
        let fixture = try ServiceFixture(records: records())
        let subject = fixture.service
        let group = try subject.createGroup(named: "开发")

        try subject.move(bundleIdentifier: "com.example.second", toGroup: group.id)

        #expect(subject.currentConfig.applications["com.example.second"]?.groupID == group.id)
    }

    @Test("组内按排序权重排，权重相同按显示名")
    func snapshotOrdersByWeightThenName() throws {
        let config = AppBoxConfig(
            groups: [.ungrouped],
            applications: [
                "com.example.heavy": ApplicationConfig(orderWeight: 10),
                "com.example.light": ApplicationConfig(orderWeight: 5),
            ]
        )
        let fixture = try ServiceFixture(
            records: [
                TestRecords.make("com.example.heavy", name: "AAA"),
                TestRecords.make("com.example.light", name: "ZZZ"),
                TestRecords.make("com.example.none", name: "MMM"),
            ],
            config: config
        )

        let names = fixture.service.snapshot().allApplications.map(\.displayName)

        // 默认权重 0 的 MMM 最先，然后权重 5 的 ZZZ，权重 10 的 AAA 垫底。
        #expect(names == ["MMM", "ZZZ", "AAA"])
    }

    @Test("调整分组顺序后落盘，重启保持")
    func reorderingSurvivesRestart() throws {
        let fixture = try ServiceFixture()
        let dev = try fixture.service.createGroup(named: "开发")
        let games = try fixture.service.createGroup(named: "游戏")

        try fixture.service.moveGroup(id: games.id, toIndex: 0)

        #expect(fixture.service.currentConfig.groups.map(\.id) == [games.id, Group.ungroupedID, dev.id])
    }

    @Test("越界的目标位置被夹到两端，而不是报错")
    func reorderClampsOutOfRangeIndex() throws {
        let subject = try ServiceFixture().service
        let group = try subject.createGroup(named: "开发")

        try subject.moveGroup(id: group.id, toIndex: 99)
        #expect(subject.currentConfig.groups.last?.id == group.id)

        try subject.moveGroup(id: group.id, toIndex: -5)
        #expect(subject.currentConfig.groups.first?.id == group.id)
    }
}
