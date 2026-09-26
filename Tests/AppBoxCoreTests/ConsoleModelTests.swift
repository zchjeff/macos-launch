import Foundation
import Testing

@testable import AppBoxCore

@MainActor
@Suite("控制台：加载与选中")
struct ConsoleLoadingTests {
    @Test("首轮加载后「未分类」排在首位并被默认选中")
    func selectsUngroupedOnLoad() async throws {
        let model = ConsoleModel(service: try ServiceFixture().service)

        await model.refresh()

        #expect(model.groups.map(\.group.id) == [Group.ungroupedID])
        #expect(model.selectedGroupID == Group.ungroupedID)
        #expect(model.applications.isEmpty)
        #expect(model.isLoading == false)
    }

    @Test("右侧列出选中分组的应用，未分类的那部分不混进来")
    func listsSelectedGroupApplications() async throws {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.first", name: "First"),
            TestRecords.make("com.example.second", name: "Second"),
        ])
        let model = ConsoleModel(service: fixture.service)
        await model.createGroup(named: "开发")
        let dev = try #require(model.selectedGroupID)

        await model.move("com.example.first", toGroup: dev)

        #expect(model.applications.map(\.bundleIdentifier) == ["com.example.first"])
        let ungrouped = try #require(model.groups.first { $0.group.isUngrouped })
        #expect(ungrouped.applications.map(\.bundleIdentifier) == ["com.example.second"])
    }

    @Test("空分组留在左侧列表里，不自动消失")
    func keepsEmptyGroups() async throws {
        let model = ConsoleModel(service: try ServiceFixture().service)

        await model.createGroup(named: "空组")

        #expect(model.groups.map(\.group.name) == ["未分类", "空组"])
        #expect(model.applications.isEmpty)
        #expect(model.selectedGroup?.name == "空组")
    }

    @Test("新建的分组排在末尾，并成为当前选中")
    func selectsNewlyCreatedGroup() async throws {
        let model = ConsoleModel(service: try ServiceFixture().service)

        await model.createGroup(named: "开发")
        await model.createGroup(named: "游戏")

        #expect(model.groups.map(\.group.name) == ["未分类", "开发", "游戏"])
        #expect(model.selectedGroup?.name == "游戏")
    }

    @Test("选中的分组没了，选中落回「未分类」而不是留空")
    func fallsBackWhenSelectionDisappears() async throws {
        let fixture = try ServiceFixture(records: [TestRecords.make("com.example.app", name: "App")])
        let model = ConsoleModel(service: fixture.service)
        await model.createGroup(named: "开发")
        let dev = try #require(model.selectedGroupID)

        model.requestDelete(dev)
        await model.confirmDelete()

        #expect(model.selectedGroupID == Group.ungroupedID)
        #expect(model.applications.map(\.bundleIdentifier) == ["com.example.app"])
    }
}

@MainActor
@Suite("控制台：重命名")
struct ConsoleRenameTests {
    private func modelWithGroup(_ name: String = "开发") async throws -> (ConsoleModel, String) {
        let model = ConsoleModel(service: try ServiceFixture().service)
        await model.createGroup(named: name)
        return (model, try #require(model.selectedGroupID))
    }

    @Test("重命名后列表里的名字变了，而且落了盘")
    func renamesAndPersists() async throws {
        let fixture = try ServiceFixture()
        let model = ConsoleModel(service: fixture.service)
        await model.createGroup(named: "开发")
        let dev = try #require(model.selectedGroupID)

        await model.rename(dev, to: "编程")

        #expect(model.groups.map(\.group.name) == ["未分类", "编程"])
        #expect(fixture.service.currentConfig.groups.map(\.name) == ["未分类", "编程"])
    }

    @Test("重命名「未分类」被拒绝，界面给出说法，名字不变")
    func refusesRenamingUngrouped() async throws {
        let model = ConsoleModel(service: try ServiceFixture().service)
        await model.refresh()

        await model.rename(Group.ungroupedID, to: "别的名字")

        #expect(model.errorMessage?.contains("未分类") == true)
        #expect(model.groups.map(\.group.name) == ["未分类"])
    }

    @Test("空名字被拒绝，界面给出说法，名字不变")
    func refusesEmptyName() async throws {
        let (model, dev) = try await modelWithGroup()

        await model.rename(dev, to: "   ")

        #expect(model.errorMessage?.contains("不能为空") == true)
        #expect(model.groups.map(\.group.name) == ["未分类", "开发"])
    }

    @Test("重命名不存在的分组会给出说法，而不是静默失败")
    func reportsMissingGroup() async throws {
        let model = ConsoleModel(service: try ServiceFixture().service)
        await model.refresh()

        await model.rename("nope", to: "无所谓")

        #expect(model.errorMessage?.contains("找不到分组") == true)
    }

    @Test("下一次操作成功之后，上一条错误提示就清掉了")
    func clearsErrorOnNextSuccess() async throws {
        let (model, _) = try await modelWithGroup()
        await model.rename("nope", to: "无所谓")
        #expect(model.errorMessage != nil)

        await model.createGroup(named: "另一个")

        #expect(model.errorMessage == nil)
    }
}

@MainActor
@Suite("控制台：删除分组要过确认")
struct ConsoleDeletionTests {
    private func fixtureWithDevGroup() throws -> ServiceFixture {
        try ServiceFixture(records: [
            TestRecords.make("com.example.first", name: "First"),
            TestRecords.make("com.example.second", name: "Second"),
        ])
    }

    private func modelWithDevGroup(_ fixture: ServiceFixture) async throws -> (ConsoleModel, String) {
        let model = ConsoleModel(service: fixture.service)
        await model.createGroup(named: "开发")
        let dev = try #require(model.selectedGroupID)
        await model.move("com.example.first", toGroup: dev)
        await model.move("com.example.second", toGroup: dev)
        return (model, dev)
    }

    @Test("只请求删除时，配置一个字节都没动")
    func requestDoesNotTouchConfig() async throws {
        let fixture = try fixtureWithDevGroup()
        let (model, dev) = try await modelWithDevGroup(fixture)

        model.requestDelete(dev)

        #expect(model.deleteConfirmationMessage != nil)
        // 另起一个服务 = 从磁盘重读：分组还在。
        #expect(fixture.service.currentConfig.groups.count == 2)
    }

    @Test("确认框里说清楚有几个应用要挪窝")
    func confirmationCountsApplications() async throws {
        let fixture = try fixtureWithDevGroup()
        let (model, dev) = try await modelWithDevGroup(fixture)

        model.requestDelete(dev)

        #expect(model.deleteConfirmationMessage?.contains("2 个应用") == true)
        #expect(model.deleteConfirmationMessage?.contains("未分类") == true)
    }

    @Test("取消删除后什么都没发生")
    func cancelLeavesEverythingAlone() async throws {
        let fixture = try fixtureWithDevGroup()
        let (model, dev) = try await modelWithDevGroup(fixture)

        model.requestDelete(dev)
        model.cancelDelete()

        #expect(model.pendingDeletion == nil)
        #expect(model.deleteConfirmationMessage == nil)
        #expect(fixture.service.currentConfig.groups.count == 2)
    }

    @Test("确认删除后应用落回「未分类」，且重启后仍然如此")
    func confirmMovesApplicationsAndPersists() async throws {
        let fixture = try fixtureWithDevGroup()
        let (model, dev) = try await modelWithDevGroup(fixture)

        model.requestDelete(dev)
        await model.confirmDelete()

        #expect(model.pendingDeletion == nil)
        #expect(model.groups.map(\.group.id) == [Group.ungroupedID])

        let reopened = ConsoleModel(service: fixture.service)
        await reopened.refresh()
        #expect(reopened.applications.map(\.bundleIdentifier).count == 2)
    }

    @Test("删除「未分类」被拒绝——界面上不给入口，模型这一层也照拦")
    func refusesDeletingUngrouped() async throws {
        let model = ConsoleModel(service: try ServiceFixture().service)
        await model.refresh()

        model.requestDelete(Group.ungroupedID)
        await model.confirmDelete()

        #expect(model.errorMessage?.contains("未分类") == true)
        #expect(model.groups.map(\.group.id) == [Group.ungroupedID])
    }
}

@MainActor
@Suite("控制台：分组排序")
struct ConsoleGroupOrderTests {
    private func modelWithTwoGroups() async throws -> (ConsoleModel, ServiceFixture) {
        let fixture = try ServiceFixture()
        let model = ConsoleModel(service: fixture.service)
        await model.createGroup(named: "开发")
        await model.createGroup(named: "游戏")
        return (model, fixture)
    }

    @Test("往后拖一位只挪一位，不会多走")
    func movingDownByOneMovesExactlyOne() async throws {
        let (model, _) = try await modelWithTwoGroups()
        #expect(model.groups.map(\.group.name) == ["未分类", "开发", "游戏"])

        // 把「开发」拖到「游戏」后面。onMove 的落点是移除之前的坐标系，
        // 所以落在下标 3 表示「排在原下标 2 的后面」。
        await model.moveGroups(fromOffsets: IndexSet(integer: 1), toOffset: 3)

        #expect(model.groups.map(\.group.name) == ["未分类", "游戏", "开发"])
    }

    @Test("往前拖一位")
    func movingUpByOneMovesExactlyOne() async throws {
        let (model, _) = try await modelWithTwoGroups()

        await model.moveGroups(fromOffsets: IndexSet(integer: 2), toOffset: 1)

        #expect(model.groups.map(\.group.name) == ["未分类", "游戏", "开发"])
    }

    @Test("分组顺序落盘，重启保持")
    func persistsGroupOrder() async throws {
        let (model, fixture) = try await modelWithTwoGroups()

        await model.moveGroups(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        #expect(model.groups.map(\.group.name) == ["游戏", "未分类", "开发"])
        let reopened = ConsoleModel(service: fixture.service)
        await reopened.refresh()
        #expect(reopened.groups.map(\.group.name) == ["游戏", "未分类", "开发"])
    }
}

@MainActor
@Suite("控制台：应用的归组与排序")
struct ConsoleApplicationTests {
    private func fixture() throws -> ServiceFixture {
        try ServiceFixture(records: [
            TestRecords.make("com.example.first", name: "First"),
            TestRecords.make("com.example.second", name: "Second"),
            TestRecords.make("com.example.third", name: "Third"),
        ])
    }

    @Test("把应用拖到某个分组后，它出现在那一组，不再出现在「未分类」")
    func movesApplicationIntoGroup() async throws {
        let fixture = try fixture()
        let model = ConsoleModel(service: fixture.service)
        await model.createGroup(named: "开发")
        let dev = try #require(model.selectedGroupID)

        await model.move("com.example.first", toGroup: dev)

        #expect(model.applications.map(\.bundleIdentifier) == ["com.example.first"])
        let ungrouped = try #require(model.groups.first { $0.group.isUngrouped })
        #expect(ungrouped.applications.map(\.bundleIdentifier) == ["com.example.second", "com.example.third"])
    }

    @Test("移入不存在的分组被拒绝并给出说法")
    func refusesMovingToMissingGroup() async throws {
        let fixture = try fixture()
        let model = ConsoleModel(service: fixture.service)
        await model.refresh()

        await model.move("com.example.first", toGroup: "nope")

        #expect(model.errorMessage?.contains("找不到分组") == true)
        #expect(model.applications.count == 3)
    }

    @Test("拖动排序后顺序落盘，重启保持")
    func reorderPersists() async throws {
        let fixture = try fixture()
        let model = ConsoleModel(service: fixture.service)
        await model.refresh()
        #expect(model.applications.map(\.bundleIdentifier)
            == ["com.example.first", "com.example.second", "com.example.third"])

        // 把 First 拖到 Third 的下半区 = 放到列表末尾。
        await model.move("com.example.first", onto: "com.example.third", placeAfter: true)

        #expect(model.applications.map(\.bundleIdentifier)
            == ["com.example.second", "com.example.third", "com.example.first"])
        let reopened = ConsoleModel(service: fixture.service)
        await reopened.refresh()
        #expect(reopened.applications.map(\.bundleIdentifier)
            == ["com.example.second", "com.example.third", "com.example.first"])
    }

    @Test("落点在行内偏上插到前面，偏下插到后面")
    func placementFollowsDropHalf() async throws {
        let model = ConsoleModel(service: try fixture().service)
        await model.refresh()

        await model.move("com.example.first", onto: "com.example.second", placeAfter: true)
        #expect(model.applications.map(\.bundleIdentifier)
            == ["com.example.second", "com.example.first", "com.example.third"])

        await model.move("com.example.third", onto: "com.example.first", placeAfter: false)
        #expect(model.applications.map(\.bundleIdentifier)
            == ["com.example.second", "com.example.third", "com.example.first"])
    }

    @Test("拖到自己身上不动，也不写盘")
    func droppingOntoItselfIsANoOp() async throws {
        let fixture = try fixture()
        let model = ConsoleModel(service: fixture.service)
        await model.refresh()

        await model.move("com.example.second", onto: "com.example.second", placeAfter: true)

        #expect(model.applications.map(\.bundleIdentifier)
            == ["com.example.first", "com.example.second", "com.example.third"])
        #expect(fixture.service.currentConfig.applications.isEmpty)
    }

    @Test("排过序之后新装的应用排在最前面，而不是插进中间")
    func newApplicationSortsFirstAfterManualOrder() async throws {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.first", name: "First"),
            TestRecords.make("com.example.second", name: "Second"),
        ])
        let model = ConsoleModel(service: fixture.service)
        await model.refresh()
        await model.move("com.example.second", onto: "com.example.first", placeAfter: false)
        #expect(model.applications.map(\.bundleIdentifier) == ["com.example.second", "com.example.first"])

        // 手排过之后，没排过的新应用权重仍是默认的 0，排在所有编号之前。
        fixture.scanner.setRecords([
            TestRecords.make("com.example.first", name: "First"),
            TestRecords.make("com.example.second", name: "Second"),
            TestRecords.make("com.example.znew", name: "Znew"),
        ])
        await model.refresh()

        #expect(model.applications.map(\.bundleIdentifier)
            == ["com.example.znew", "com.example.second", "com.example.first"])
    }

    @Test("排序只动被拖的那一组，别的组不受影响")
    func reorderLeavesOtherGroupsAlone() async throws {
        let fixture = try fixture()
        let model = ConsoleModel(service: fixture.service)
        await model.createGroup(named: "开发")
        let dev = try #require(model.selectedGroupID)
        await model.move("com.example.first", toGroup: dev)
        await model.move("com.example.third", toGroup: dev)

        await model.move("com.example.third", onto: "com.example.first", placeAfter: false)

        let ungrouped = try #require(model.groups.first { $0.group.isUngrouped })
        #expect(ungrouped.applications.map(\.bundleIdentifier) == ["com.example.second"])
        #expect(model.applications.map(\.bundleIdentifier) == ["com.example.third", "com.example.first"])
    }
}
