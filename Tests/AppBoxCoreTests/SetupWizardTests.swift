import Foundation
import Testing

@testable import AppBoxCore

@MainActor
@Suite("引导向导：逐条修改与写入")
struct SetupWizardTests {
    private func suggestion(_ name: String, _ identifiers: [String]) -> SetupSuggestion {
        SetupSuggestion(
            name: name,
            applications: identifiers.map { TestEntries.make($0, name: $0.uppercased()) }
        )
    }

    private func plan(
        _ suggestions: [SetupSuggestion],
        unassigned: [ApplicationEntry] = []
    ) -> SetupPlan {
        SetupPlan(suggestions: suggestions, unassigned: unassigned)
    }

    private func firstLaunch(records: [AppRecord] = []) throws -> ServiceFixture {
        try ServiceFixture.firstLaunch(records: records)
    }

    // MARK: - 改名

    @Test("改名去掉首尾空白后生效")
    func renameTrimsWhitespace() throws {
        let model = SetupWizardModel(
            service: try firstLaunch().service,
            plan: plan([suggestion("工具", ["com.example.a"])])
        )

        model.rename("工具", to: "  小工具  ")

        #expect(model.suggestions.map(\.name) == ["小工具"])
        #expect(model.errorMessage == nil)
    }

    @Test("空名字被拒绝：名字不变，并且有话说")
    func renameRejectsEmptyName() throws {
        let model = SetupWizardModel(
            service: try firstLaunch().service,
            plan: plan([suggestion("工具", ["com.example.a"])])
        )

        model.rename("工具", to: "   ")

        #expect(model.suggestions.map(\.name) == ["工具"])
        #expect(model.errorMessage == GroupError.emptyName.localizedDescription)
    }

    @Test("改成别的建议已有的名字会被拒绝，并指向「并入」")
    func renameRejectsDuplicateName() throws {
        let model = SetupWizardModel(
            service: try firstLaunch().service,
            plan: plan([
                suggestion("工具", ["com.example.a"]),
                suggestion("游戏", ["com.example.b"]),
            ])
        )

        model.rename("工具", to: "游戏")

        #expect(model.suggestions.map(\.name) == ["工具", "游戏"])
        let message = try #require(model.errorMessage)
        #expect(message.contains("并入"))
    }

    @Test("改成自己原来的名字不算冲突")
    func renamingToItsOwnNameIsFine() throws {
        let model = SetupWizardModel(
            service: try firstLaunch().service,
            plan: plan([suggestion("工具", ["com.example.a"])])
        )

        model.rename("工具", to: "工具")

        #expect(model.suggestions.map(\.name) == ["工具"])
        #expect(model.errorMessage == nil)
    }

    // MARK: - 合并与删除

    @Test("合并：成员并进目标，源消失，未分类数量不变")
    func mergeFoldsMembersIntoTheTarget() throws {
        let model = SetupWizardModel(
            service: try firstLaunch().service,
            plan: plan([
                suggestion("工具", ["com.example.a"]),
                suggestion("开发工具", ["com.example.b", "com.example.c"]),
            ])
        )

        model.merge("工具", into: "开发工具")

        #expect(model.suggestions.map(\.name) == ["开发工具"])
        #expect(model.suggestions.first?.applications.map(\.bundleIdentifier) == ["com.example.a", "com.example.b", "com.example.c"])
        #expect(model.unclassifiedCount == 0)
    }

    @Test("合并到自己身上什么都不做")
    func mergingIntoItselfDoesNothing() throws {
        let model = SetupWizardModel(
            service: try firstLaunch().service,
            plan: plan([suggestion("工具", ["com.example.a"])])
        )

        model.merge("工具", into: "工具")

        #expect(model.suggestions.map(\.name) == ["工具"])
        #expect(model.errorMessage == nil)
    }

    @Test("合并的目标不存在时什么都不做")
    func mergingIntoAMissingTargetDoesNothing() throws {
        let model = SetupWizardModel(
            service: try firstLaunch().service,
            plan: plan([suggestion("工具", ["com.example.a"])])
        )

        model.merge("工具", into: "查无此组")

        #expect(model.suggestions.map(\.name) == ["工具"])
    }

    @Test("删除建议：应用回到「未分类」")
    func removingASuggestionReturnsItsApplications() throws {
        let model = SetupWizardModel(
            service: try firstLaunch().service,
            plan: plan(
                [suggestion("工具", ["com.example.a", "com.example.b"])],
                unassigned: [TestEntries.make("com.example.loose", name: "Loose")]
            )
        )
        #expect(model.unclassifiedCount == 1)

        model.remove("工具")

        #expect(model.suggestions.isEmpty)
        #expect(model.unclassifiedCount == 3)
    }

    @Test("跳过：不写进配置，但建议留在列表里等着反悔")
    func skippingKeepsTheSuggestionButExcludesIt() throws {
        let model = SetupWizardModel(
            service: try firstLaunch().service,
            plan: plan([
                suggestion("工具", ["com.example.a"]),
                suggestion("游戏", ["com.example.b"]),
            ])
        )

        model.skip("工具")

        #expect(model.suggestions.count == 2)
        #expect(model.isSkipped("工具"))
        #expect(model.acceptedCount == 1)
        #expect(model.unclassifiedCount == 1)

        model.restore("工具")

        #expect(!model.isSkipped("工具"))
        #expect(model.acceptedCount == 2)
        #expect(model.unclassifiedCount == 0)
    }

    @Test("跳过的建议不会写进配置，但它名下的应用仍然算「有归属」——只是留在未分类")
    func skippedSuggestionsAreNotWritten() async throws {
        let fixture = try firstLaunch(records: [
            TestRecords.make("com.example.a", name: "A", category: "public.app-category.utilities"),
            TestRecords.make("com.example.b", name: "B", category: "public.app-category.games"),
        ])
        let model = SetupWizardModel(
            service: fixture.service,
            plan: plan([
                suggestion("工具", ["com.example.a"]),
                suggestion("游戏", ["com.example.b"]),
            ])
        )
        model.skip("工具")

        #expect(await model.confirm())

        let config = fixture.service.currentConfig
        #expect(config.groups.map(\.name) == ["未分类", "游戏"])
        #expect(config.applications["com.example.a"] == nil)
        #expect(config.applications["com.example.b"]?.groupID != Group.ungroupedID)
    }

    // MARK: - 写入

    @Test("改来改去但没确认：磁盘上仍然没有配置文件")
    func nothingIsWrittenBeforeConfirmation() throws {
        let fixture = try firstLaunch()
        let url = try fixture.store.profileURL(named: AppBoxConfig.defaultProfileName)
        let model = SetupWizardModel(
            service: fixture.service,
            plan: plan([suggestion("工具", ["com.example.a"])])
        )

        model.rename("工具", to: "小工具")
        model.remove("工具")

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(fixture.service.currentConfig.groups == [.ungrouped])
    }

    @Test("确认后一次落盘：分组、成员归属、顺序都对")
    func confirmationWritesEverythingAtOnce() async throws {
        let fixture = try firstLaunch(records: [
            TestRecords.make("com.example.a", name: "A", category: "public.app-category.utilities"),
            TestRecords.make("com.example.b", name: "B", category: "public.app-category.utilities"),
            TestRecords.make("com.example.c", name: "C", category: "public.app-category.games"),
            TestRecords.make("com.example.loose", name: "Loose"),
        ])
        let model = SetupWizardModel(
            service: fixture.service,
            plan: plan([
                suggestion("工具", ["com.example.a", "com.example.b"]),
                suggestion("游戏", ["com.example.c"]),
            ], unassigned: [TestEntries.make("com.example.loose", name: "Loose")])
        )

        #expect(model.unclassifiedCount == 1)
        #expect(await model.confirm())

        // 重开一个服务读磁盘：写进去的东西自己站得住。
        let config = fixture.service.currentConfig
        #expect(config.groups.map(\.name) == ["未分类", "工具", "游戏"])
        let tools = try #require(config.groups.first { $0.name == "工具" })
        let games = try #require(config.groups.first { $0.name == "游戏" })
        #expect(config.applications["com.example.a"]?.groupID == tools.id)
        #expect(config.applications["com.example.b"]?.groupID == tools.id)
        #expect(config.applications["com.example.c"]?.groupID == games.id)
        // 未分类的那位不进配置：没人动过它。
        #expect(config.applications["com.example.loose"] == nil)
    }

    @Test("确认后「首次启动」这件事就算过去了：下次加载读到的是磁盘上的配置")
    func confirmationEndsFirstLaunch() async throws {
        let fixture = try firstLaunch(records: [TestRecords.make("com.example.a", name: "A")])
        #expect(fixture.service.loadOutcome == .createdDefault(AppBoxConfig()))

        let model = SetupWizardModel(
            service: fixture.service,
            plan: plan([suggestion("工具", ["com.example.a"])])
        )
        #expect(await model.confirm())

        let fresh = fixture.service
        #expect(fresh.loadOutcome == .loaded(fresh.currentConfig))
    }

    @Test("取消：配置落盘为初始状态，向导不再出现")
    func cancellationPersistsTheInitialConfig() async throws {
        let fixture = try firstLaunch(records: [TestRecords.make("com.example.loose", name: "Loose")])
        let model = SetupWizardModel(
            service: fixture.service,
            plan: plan([suggestion("工具", ["com.example.a"])])
        )

        #expect(await model.cancel())

        let fresh = fixture.service
        #expect(fresh.loadOutcome == .loaded(AppBoxConfig()))
        #expect(fresh.currentConfig.groups == [.ungrouped])
        #expect(fresh.currentConfig.applications.isEmpty)
    }

    @Test("确认失败时留在向导里，把失败的说法带出来")
    func failedConfirmationKeepsTheWizardOpen() async throws {
        let fixture = try firstLaunch(records: [TestRecords.make("com.example.a", name: "A")])
        let model = SetupWizardModel(
            service: fixture.service,
            plan: plan([suggestion("   ", ["com.example.a"])])
        )

        #expect(!(await model.confirm()))
        #expect(model.errorMessage == GroupError.emptyName.localizedDescription)
    }

    // MARK: - 汇总

    @Test("汇总计数：采纳几条、覆盖几个应用、多少留在未分类")
    func summaryCounts() throws {
        let model = SetupWizardModel(
            service: try firstLaunch().service,
            plan: plan(
                [
                    suggestion("工具", ["com.example.a", "com.example.b"]),
                    suggestion("游戏", ["com.example.c"]),
                ],
                unassigned: [TestEntries.make("com.example.loose", name: "Loose")]
            )
        )

        #expect(model.acceptedCount == 2)
        #expect(model.assignedCount == 3)
        #expect(model.totalCount == 4)
        #expect(model.unclassifiedCount == 1)
    }

    @Test("认不出的类别跟着计划一起带进来，界面好提醒一句")
    func unrecognizedCategoriesAreCarriedThrough() throws {
        let plan = SetupPlan(
            suggestions: [suggestion("工具", ["com.example.a"])],
            unassigned: [TestEntries.make("com.example.b", name: "B", category: "public.app-category.nope")],
            unrecognizedCategories: ["public.app-category.nope"]
        )
        let model = SetupWizardModel(service: try firstLaunch().service, plan: plan)

        #expect(model.unrecognizedCategories == ["public.app-category.nope"])
    }
}

@MainActor
@Suite("引导整理：一次落盘")
struct SetupApplicationTests {
    @Test("空计划也写盘：文件存在与否就是「首启过没过」的标志")
    func emptyPlanStillPersists() throws {
        let fixture = try ServiceFixture.firstLaunch()
        let url = try fixture.store.profileURL(named: AppBoxConfig.defaultProfileName)

        try fixture.service.applySetup([])

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(fixture.service.loadOutcome == .loaded(AppBoxConfig()))
    }

    @Test("多个分组一次建好，顺序就是计划里的顺序")
    func createsEveryGroupInOneWrite() throws {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.a", name: "A"),
            TestRecords.make("com.example.b", name: "B"),
        ])

        try fixture.service.applySetup([
            GroupPlan(name: "工具", members: ["com.example.a"]),
            GroupPlan(name: "游戏", members: ["com.example.b"]),
        ])

        let config = fixture.service.currentConfig
        #expect(config.groups.map(\.name) == ["未分类", "工具", "游戏"])
        let tools = try #require(config.groups.first { $0.name == "工具" })
        #expect(config.applications["com.example.a"]?.groupID == tools.id)
    }

    @Test("只改归属：应用已有的别名、隐藏、锁定一个都不动")
    func keepsOtherSettingsOfTheMembers() throws {
        let fixture = try ServiceFixture(records: [TestRecords.make("com.example.a", name: "A")])
        try fixture.service.setAlias("我的别名", for: "com.example.a")
        try fixture.service.setHidden(true, for: "com.example.a")
        try fixture.service.setLocked(true, for: "com.example.a")

        try fixture.service.applySetup([GroupPlan(name: "工具", members: ["com.example.a"])])

        let entry = try #require(
            fixture.service.snapshot().groups.first { $0.group.name == "工具" }?.applications.first
        )
        #expect(entry.alias == "我的别名")
        #expect(entry.isHidden)
        #expect(entry.isLocked)
    }

    @Test("分组名不合法：整体拒绝，磁盘一个字节都不动")
    func rejectsInvalidNamesAsAWhole() throws {
        let fixture = try ServiceFixture(records: [TestRecords.make("com.example.a", name: "A")])

        #expect(throws: GroupError.emptyName) {
            try fixture.service.applySetup([
                GroupPlan(name: "工具", members: ["com.example.a"]),
                GroupPlan(name: "   ", members: []),
            ])
        }

        // 前半段合法也不许落一半：要么整份计划成立，要么什么都不发生。
        #expect(fixture.service.currentConfig.groups == [.ungrouped])
        #expect(fixture.service.currentConfig.applications.isEmpty)
    }
}

@MainActor
@Suite("引导整理：从控制台进入")
struct ConsoleSetupTests {
    @Test("首启进入向导：建议取自「未分类」里的应用")
    func beginsSetupFromUngroupedApplications() async throws {
        let fixture = try ServiceFixture.firstLaunch(records: [
            TestRecords.make("com.example.term", name: "Term", category: "public.app-category.utilities"),
            TestRecords.make("com.example.game", name: "Game", category: "public.app-category.games"),
            TestRecords.make("com.example.loose", name: "Loose"),
        ])
        let model = ConsoleModel(service: fixture.service)

        await model.beginSetup()

        let setup = try #require(model.setup)
        // 两条建议各一个应用，数量相同时的先后跟语言环境有关——这里只断言两条都在。
        #expect(Set(setup.suggestions.map(\.name)) == ["游戏", "工具"])
        #expect(setup.unclassifiedCount == 1)
        // 没开始整理之前，控制台里就是一条「未分类」。
        #expect(model.groups.map(\.group.name) == ["未分类"])
    }

    @Test("向导结束：回到普通控制台，列表按刚写下去的分组建好")
    func endsSetupAndReloads() async throws {
        let fixture = try ServiceFixture.firstLaunch(records: [
            TestRecords.make("com.example.term", name: "Term", category: "public.app-category.utilities"),
        ])
        let model = ConsoleModel(service: fixture.service)
        await model.beginSetup()
        let setup = try #require(model.setup)

        #expect(await setup.confirm())
        await model.endSetup()

        #expect(model.setup == nil)
        #expect(model.groups.map(\.group.name) == ["未分类", "工具"])
        #expect(model.applications.isEmpty)
    }

    @Test("不是首启就不会自动进向导")
    func setupDoesNotStartOnItsOwn() async throws {
        let fixture = try ServiceFixture(records: [TestRecords.make("com.example.a", name: "A")])
        let model = ConsoleModel(service: fixture.service)

        await model.refresh()

        #expect(model.setup == nil)
    }
}
