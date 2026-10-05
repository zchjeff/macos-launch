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

    @Test("确认框先关后动作才跑：删除照样落盘")
    func confirmTakesTheSnapshotFromTheDialog() async throws {
        let fixture = try fixtureWithDevGroup()
        let (model, dev) = try await modelWithDevGroup(fixture)

        model.requestDelete(dev)
        // 界面上的真实时序：确认框一关，绑定 setter 就把待确认项清掉了，
        // 而按钮动作是 `Task` 异步派发的。少了确认框递给它的那一份，这一次确认会静默落空。
        let target = try #require(model.pendingDeletion)
        model.cancelDelete()

        await model.confirmDelete(target)

        #expect(fixture.service.currentConfig.groups.count == 1)
        #expect(model.groups.map(\.group.id) == [Group.ungroupedID])
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

    @Test("排过序之后新装的应用排在末尾，而不是插进排好的队列")
    func newApplicationSortsLastAfterManualOrder() async throws {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.first", name: "First"),
            TestRecords.make("com.example.second", name: "Second"),
        ])
        let model = ConsoleModel(service: fixture.service)
        await model.refresh()
        await model.move("com.example.second", onto: "com.example.first", placeAfter: false)
        #expect(model.applications.map(\.bundleIdentifier) == ["com.example.second", "com.example.first"])

        // 手排过之后，没排过的新应用权重仍是默认的 0，排在所有编号之后。
        fixture.scanner.setRecords([
            TestRecords.make("com.example.first", name: "First"),
            TestRecords.make("com.example.second", name: "Second"),
            TestRecords.make("com.example.znew", name: "Znew"),
        ])
        await model.refresh()

        #expect(model.applications.map(\.bundleIdentifier)
            == ["com.example.second", "com.example.first", "com.example.znew"])
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

@MainActor
@Suite("控制台：别名与隐藏")
struct ConsoleApplicationSettingsTests {
    private func fixture() throws -> ServiceFixture {
        try ServiceFixture(records: [
            TestRecords.make("com.example.keep", name: "Keep"),
            TestRecords.make("com.example.hide", name: "Hide"),
        ])
    }

    @Test("设置别名后列表显示别名，详情里真实名称还在")
    func aliasShowsInListAndDetail() async throws {
        let model = ConsoleModel(service: try fixture().service)
        await model.refresh()
        model.selectedApplicationID = "com.example.keep"

        await model.setAlias("编辑器", for: "com.example.keep")

        #expect(model.applications.first { $0.bundleIdentifier == "com.example.keep" }?.displayName == "编辑器")
        #expect(model.detail?.realName == "Keep")
        #expect(model.detail?.alias == "编辑器")
    }

    @Test("清除别名后恢复真实名称")
    func clearingAliasRestoresRealName() async throws {
        let model = ConsoleModel(service: try fixture().service)
        await model.refresh()
        model.selectedApplicationID = "com.example.keep"
        await model.setAlias("编辑器", for: "com.example.keep")

        await model.setAlias("", for: "com.example.keep")

        #expect(model.applications.first { $0.bundleIdentifier == "com.example.keep" }?.displayName == "Keep")
        #expect(model.detail?.alias == nil)
    }

    @Test("别名落盘，重启后还在")
    func aliasSurvivesRestart() async throws {
        let fixture = try fixture()
        let model = ConsoleModel(service: fixture.service)
        await model.refresh()
        await model.setAlias("编辑器", for: "com.example.keep")

        let reopened = ConsoleModel(service: fixture.service)
        await reopened.refresh()

        #expect(reopened.applications.first { $0.bundleIdentifier == "com.example.keep" }?.displayName == "编辑器")
    }

    @Test("隐藏后它从覆盖层消失，控制台里仍看得见、也能恢复")
    func hidingKeepsApplicationInConsole() async throws {
        let model = ConsoleModel(service: try fixture().service)
        await model.refresh()

        await model.setHidden(true, for: "com.example.hide")

        // 控制台列表：还在，只是标上了「已隐藏」。
        #expect(model.applications.map(\.bundleIdentifier) == ["com.example.hide", "com.example.keep"])
        #expect(model.applications.first { $0.bundleIdentifier == "com.example.hide" }?.isHidden == true)
        // 覆盖层：连分组的缩略图里都没有它。
        let ungrouped = try #require(model.groups.first { $0.group.isUngrouped })
        #expect(ungrouped.visibleApplications.map(\.bundleIdentifier) == ["com.example.keep"])

        await model.setHidden(false, for: "com.example.hide")

        let restored = try #require(model.groups.first { $0.group.isUngrouped })
        #expect(restored.visibleApplications.map(\.bundleIdentifier)
            == ["com.example.hide", "com.example.keep"])
    }

    @Test("锁定后位置被别人挤不动，解锁后又能排")
    func lockingPinsThePosition() async throws {
        let fixture = try fixture()
        let model = ConsoleModel(service: fixture.service)
        await model.refresh()
        model.selectedApplicationID = "com.example.hide"
        // 当前顺序：Hide、Keep。锁住排头那个。
        #expect(model.applications.map(\.bundleIdentifier)
            == ["com.example.hide", "com.example.keep"])

        await model.setLocked(true, for: "com.example.hide")

        #expect(model.detail?.isLocked == true)

        // 名字排在 Hide 前面的新应用：没锁定的话它会插到最前面去。
        fixture.scanner.setRecords([
            TestRecords.make("com.example.aaa", name: "AAA"),
            TestRecords.make("com.example.keep", name: "Keep"),
            TestRecords.make("com.example.hide", name: "Hide"),
        ])
        await model.refresh()
        #expect(model.applications.map(\.bundleIdentifier)
            == ["com.example.hide", "com.example.keep", "com.example.aaa"])

        await model.setLocked(false, for: "com.example.hide")
        await model.move("com.example.aaa", onto: "com.example.keep", placeAfter: false)
        #expect(model.applications.map(\.bundleIdentifier)
            == ["com.example.hide", "com.example.aaa", "com.example.keep"])
    }
}

@MainActor
@Suite("控制台：应用详情")
struct ConsoleDetailTests {
    private func model() async throws -> ConsoleModel {
        let fixture = try ServiceFixture(
            records: [
                TestRecords.make("com.example.first", name: "First", path: "/Applications/First.app"),
                TestRecords.make("com.example.second", name: "Second"),
            ]
        )
        let model = ConsoleModel(service: fixture.service)
        await model.refresh()
        return model
    }

    @Test("没选中应用时详情面板是空的")
    func detailIsEmptyWithoutSelection() async throws {
        let model = try await model()

        #expect(model.selectedApplicationID == nil)
        #expect(model.detail == nil)
    }

    @Test("选中应用后详情说清它是谁、在哪、归哪一组")
    func detailDescribesSelectedApplication() async throws {
        let model = try await model()

        model.selectedApplicationID = "com.example.first"

        let detail = try #require(model.detail)
        #expect(detail.realName == "First")
        #expect(detail.bundleIdentifier == "com.example.first")
        #expect(detail.lastKnownPath == "/Applications/First.app")
        #expect(detail.groupName == "未分类")
        #expect(detail.isHidden == false)
        #expect(detail.isLocked == false)
        #expect(detail.isMissing == false)
    }

    @Test("详情里的分组名是它所在的那一组")
    func detailNamesTheOwningGroup() async throws {
        let model = try await model()
        await model.createGroup(named: "开发")
        let dev = try #require(model.selectedGroupID)
        await model.move("com.example.first", toGroup: dev)

        model.selectedApplicationID = "com.example.first"

        #expect(model.detail?.groupName == "开发")
    }

    @Test("换分组后原先选中的应用不再占着详情面板")
    func selectionClearsWhenGroupChanges() async throws {
        let model = try await model()
        model.selectedApplicationID = "com.example.first"
        #expect(model.detail != nil)

        await model.createGroup(named: "开发")

        #expect(model.selectedApplicationID == nil)
        #expect(model.detail == nil)
    }

    @Test("选中失效记录：详情说得出别名、最后位置与「已失效」")
    func detailDescribesMissingRecord() async throws {
        let fixture = try ServiceFixture(
            config: AppBoxConfig(
                groups: [.ungrouped, Group(id: "dev", name: "开发")],
                applications: [
                    "com.example.gone": ApplicationConfig(
                        groupID: "dev",
                        alias: "走丢的",
                        hidden: true,
                        lastKnownPath: "/Applications/Gone.app"
                    )
                ]
            )
        )
        let model = ConsoleModel(service: fixture.service)
        await model.refresh()

        model.selection = .missing
        model.selectedApplicationID = "com.example.gone"

        let detail = try #require(model.detail)
        #expect(detail.isMissing)
        #expect(detail.realName == nil)
        #expect(detail.alias == "走丢的")
        #expect(detail.lastKnownPath == "/Applications/Gone.app")
        #expect(detail.groupName == "开发")
        #expect(detail.isHidden)
    }
}

@MainActor
@Suite("控制台：失效列表与清理")
struct ConsoleMissingTests {
    private func fixture() throws -> ServiceFixture {
        try ServiceFixture(config: AppBoxConfig(
            groups: [.ungrouped, Group(id: "dev", name: "开发")],
            applications: [
                "com.example.gone": ApplicationConfig(
                    groupID: "dev",
                    alias: "走丢的",
                    lastKnownPath: "/Applications/Gone.app"
                )
            ]
        ))
    }

    @Test("失效列表就是「配置里有、磁盘上找不到」的那些")
    func listsMissingApplications() async throws {
        let model = ConsoleModel(service: try fixture().service)

        await model.refresh()

        #expect(model.missing.map(\.bundleIdentifier) == ["com.example.gone"])
    }

    @Test("只请求清理时，配置一个字节都没动")
    func requestDoesNotTouchConfig() async throws {
        let fixture = try fixture()
        let model = ConsoleModel(service: fixture.service)
        await model.refresh()

        model.requestForget("com.example.gone")

        #expect(model.forgetConfirmationMessage?.contains("走丢的") == true)
        #expect(model.forgetConfirmationMessage?.contains("别名") == true)
        // 另起一个服务 = 从磁盘重读：记录还在。
        #expect(fixture.service.currentConfig.applications["com.example.gone"] != nil)
    }

    @Test("取消清理后什么都没发生")
    func cancelLeavesEverythingAlone() async throws {
        let fixture = try fixture()
        let model = ConsoleModel(service: fixture.service)
        await model.refresh()

        model.requestForget("com.example.gone")
        model.cancelForget()

        #expect(model.pendingForget == nil)
        #expect(model.forgetConfirmationMessage == nil)
        #expect(fixture.service.currentConfig.applications["com.example.gone"] != nil)
    }

    @Test("确认框先关后动作才跑：清理照样落盘")
    func confirmTakesTheRecordFromTheDialog() async throws {
        let fixture = try fixture()
        let model = ConsoleModel(service: fixture.service)
        await model.refresh()
        model.selection = .missing

        model.requestForget("com.example.gone")
        // 同确认框的真实时序：关闭先于异步动作，待确认项那时已经不在模型里了。
        let target = try #require(model.pendingForget)
        model.cancelForget()

        await model.confirmForget(target)

        #expect(fixture.service.currentConfig.applications["com.example.gone"] == nil)
        #expect(model.missing.isEmpty)
    }

    @Test("确认清理后记录连同别名、分组一起消失，重启后仍然没有")
    func confirmForgetsTheRecord() async throws {
        let fixture = try fixture()
        let model = ConsoleModel(service: fixture.service)
        await model.refresh()
        model.selection = .missing

        model.requestForget("com.example.gone")
        await model.confirmForget()

        #expect(model.pendingForget == nil)
        #expect(model.missing.isEmpty)
        #expect(fixture.service.currentConfig.applications["com.example.gone"] == nil)
        // 清完最后一笔，界面落回「未分类」，不会停在一栏已经不存在的列表上。
        #expect(model.selectedGroupID == Group.ungroupedID)
    }

    @Test("清理一条不在列表里的记录：什么都不发生，也不报错")
    func forgettingUnknownRecordIsHarmless() async throws {
        let model = ConsoleModel(service: try fixture().service)
        await model.refresh()

        model.requestForget("com.example.never")

        #expect(model.pendingForget == nil)
        await model.confirmForget()
        #expect(model.errorMessage == nil)
        #expect(model.missing.map(\.bundleIdentifier) == ["com.example.gone"])
    }
}

@MainActor
@Suite("控制台：组内搜索过滤")
struct ConsoleSearchFilterTests {
    private func model() async throws -> ConsoleModel {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.wechat", name: "微信"),
            TestRecords.make("com.example.xcode", name: "Xcode"),
            TestRecords.make("com.example.xmind", name: "XMind"),
        ])
        let model = ConsoleModel(service: fixture.service)
        await model.refresh()
        return model
    }

    @Test("查询命中名字：只留命中的行，顺序不变")
    func filtersByDisplayName() async throws {
        let model = try await model()
        model.query = "xc"

        #expect(model.filteredApplications.map(\.bundleIdentifier) == ["com.example.xcode"])
    }

    @Test("拼音缩写命中：wx 找到微信")
    func filtersByPinyinInitials() async throws {
        let model = try await model()
        model.query = "wx"

        #expect(model.filteredApplications.map(\.bundleIdentifier) == ["com.example.wechat"])
    }

    @Test("空查询不过滤：过滤结果与完整列表一致")
    func emptyQueryShowsEverything() async throws {
        let model = try await model()

        #expect(model.filteredApplications.map(\.bundleIdentifier) == model.applications.map(\.bundleIdentifier))
    }

    @Test("过滤状态下重排仍作用于完整顺序：没命中的应用不掉队")
    func reorderUnderFilterKeepsFullOrder() async throws {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.wechat", name: "微信"),
            TestRecords.make("com.example.xcode", name: "Xcode"),
            TestRecords.make("com.example.xmind", name: "XMind"),
        ])
        let model = ConsoleModel(service: fixture.service)
        await model.refresh()
        model.query = "x"

        await model.move("com.example.xmind", onto: "com.example.xcode", placeAfter: false)

        // 过滤视图里 XMind 排到了 Xcode 前面；完整列表里微信（xin 整词命中）仍在第一。
        #expect(model.filteredApplications.map(\.bundleIdentifier) == [
            "com.example.wechat", "com.example.xmind", "com.example.xcode",
        ])
        let ungrouped = try #require(model.groups.first { $0.group.isUngrouped })
        #expect(ungrouped.applications.map(\.bundleIdentifier) == [
            "com.example.wechat", "com.example.xmind", "com.example.xcode",
        ])
    }

    @Test("换分组时查询保留：搜索是视图状态，不该被选中项清掉")
    func querySurvivesGroupChange() async throws {
        let model = try await model()
        model.query = "x"
        await model.createGroup(named: "开发")

        #expect(model.query == "x")
        // 新分组是空的，过滤结果跟着空。
        #expect(model.filteredApplications.isEmpty)
    }
}

@MainActor
@Suite("控制台：全组搜索")
struct ConsoleSearchAllGroupsTests {
    private func modelWithGroups() async throws -> ConsoleModel {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.wechat", name: "微信"),
            TestRecords.make("com.example.xcode", name: "Xcode"),
            TestRecords.make("com.example.xmind", name: "XMind"),
            TestRecords.make("com.example.garageband", name: "库乐队"),
        ])
        let model = ConsoleModel(service: fixture.service)
        await model.refresh()
        await model.createGroup(named: "开发")
        let dev = try #require(model.selectedGroupID)
        await model.move("com.example.xcode", toGroup: dev)
        await model.move("com.example.garageband", toGroup: dev)
        // 当前选中的是「开发」（Xcode、库乐队）；微信、XMind 在未分类。
        return model
    }

    @Test("全部范围横穿所有分组命中：wx 在「开发」页也能搜到微信")
    func allScopeCrossesGroups() async throws {
        let model = try await modelWithGroups()
        model.query = "wx"
        #expect(model.searchScope == .group)
        #expect(model.filteredApplications.isEmpty)

        model.searchScope = .all

        #expect(model.filteredApplications.map(\.bundleIdentifier) == ["com.example.wechat"])
    }

    @Test("全部范围的顺序是分组顺序、组内顺序；空查询给出全部应用")
    func allScopeOrdersByGroupThenApplication() async throws {
        let model = try await modelWithGroups()
        model.searchScope = .all

        #expect(model.allApplications.map(\.bundleIdentifier) == [
            "com.example.wechat", "com.example.xmind",
            "com.example.garageband", "com.example.xcode",
        ])
        #expect(model.filteredApplications.map(\.bundleIdentifier) == model.allApplications.map(\.bundleIdentifier))
    }

    @Test("全组结果里选中应用：详情说的是它真正所在的分组")
    func detailNamesTheOwningGroup() async throws {
        let model = try await modelWithGroups()
        model.searchScope = .all
        model.query = "wx"
        model.selectedApplicationID = "com.example.wechat"

        #expect(model.detail?.groupName == "未分类")
    }

    @Test("从全部切回本组：不在当前分组的应用不再占着详情面板")
    func switchingBackClearsForeignSelection() async throws {
        let model = try await modelWithGroups()
        model.searchScope = .all
        model.selectedApplicationID = "com.example.wechat"
        #expect(model.detail != nil)

        model.searchScope = .group

        #expect(model.detail == nil)
    }
}

@MainActor
@Suite("控制台：开机启动开关")
struct ConsoleLoginItemTests {
    @Test("开关的初值来自端口：系统里已注册就显示为开")
    func reflectsPortStatusOnInit() async throws {
        let loginItem = FakeLoginItem(status: true)
        let model = ConsoleModel(service: try ServiceFixture().service, loginItem: loginItem)

        #expect(model.isOpenAtLogin == true)
    }

    @Test("拨开再拨关：两次都调到端口，界面跟着走")
    func togglingCallsPort() async throws {
        let loginItem = FakeLoginItem()
        let model = ConsoleModel(service: try ServiceFixture().service, loginItem: loginItem)

        model.setOpenAtLogin(true)
        #expect(model.isOpenAtLogin == true)

        model.setOpenAtLogin(false)
        #expect(model.isOpenAtLogin == false)
        #expect(loginItem.calls == [true, false])
    }

    @Test("系统拒绝注册时弹回原样，并给出说法")
    func failureRevertsSwitchAndReports() async throws {
        let loginItem = FakeLoginItem()
        loginItem.failOnSet = true
        let model = ConsoleModel(service: try ServiceFixture().service, loginItem: loginItem)

        model.setOpenAtLogin(true)

        #expect(model.isOpenAtLogin == false)
        #expect(model.errorMessage?.contains("系统拒绝注册") == true)
    }
}
