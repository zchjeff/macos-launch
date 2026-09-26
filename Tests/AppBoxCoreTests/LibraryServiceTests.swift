import Foundation
import Testing

@testable import AppBoxCore

@Suite("快照组装")
struct LibraryServiceSnapshotTests {
    @Test("快照包含扫描到的每个应用，显示名用真实名称")
    func snapshotCarriesScannedApplications() throws {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.beta", name: "Beta"),
            TestRecords.make("com.example.alpha", name: "Alpha"),
        ])

        let applications = fixture.service.snapshot().visibleApplications

        #expect(applications.map(\.bundleIdentifier) == ["com.example.alpha", "com.example.beta"])
        #expect(applications.map(\.displayName) == ["Alpha", "Beta"])
    }

    @Test("同一组内按显示名排序，而不是按扫描返回的顺序")
    func snapshotSortsByDisplayName() throws {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.c", name: "Cherry"),
            TestRecords.make("com.example.a", name: "apple"),
            TestRecords.make("com.example.b", name: "Banana"),
        ])

        let names = fixture.service.snapshot().visibleApplications.map(\.displayName)

        // localizedStandardCompare：大小写不敏感，所以 apple 排在 Banana 前。
        #expect(names == ["apple", "Banana", "Cherry"])
    }

    @Test("每个应用都向图标提供者问过图标，路径写进条目")
    func snapshotResolvesIcons() throws {
        let fixture = try ServiceFixture(records: [TestRecords.make("com.example.app", name: "App")])

        let entry = fixture.service.snapshot().visibleApplications.first

        #expect(fixture.icons.requestedIdentifiers == ["com.example.app"])
        #expect(entry?.iconCachePath == "/tmp/icons/com.example.app.png")
    }

    @Test("图标拿不到时条目仍然存在，图标路径为空")
    func snapshotToleratesMissingIcons() throws {
        let directory = try TempDirectory()
        let service = LibraryService(
            configStore: AppBoxConfigStore(directory: directory.url),
            scanner: FakeAppScanner(records: [TestRecords.make("com.example.app", name: "App")]),
            icons: EmptyIconProvider(),
            launcher: FakeLauncher()
        )

        let entry = service.snapshot().visibleApplications.first

        #expect(entry?.bundleIdentifier == "com.example.app")
        #expect(entry?.iconCachePath == nil)
    }

    @Test("没有扫描到任何应用时，快照只有空分组而不是崩掉")
    func emptyScanYieldsEmptySnapshot() throws {
        let fixture = try ServiceFixture()

        let snapshot = fixture.service.snapshot()

        #expect(snapshot.visibleApplications.isEmpty)
        #expect(snapshot.groups.map(\.group.id) == [Group.ungroupedID])
    }

    @Test("路径与类别原样带进条目，供后续切片使用")
    func snapshotCarriesPathAndCategory() throws {
        let fixture = try ServiceFixture(records: [
            TestRecords.make(
                "com.example.app",
                name: "App",
                path: "/Applications/Utilities/App.app",
                category: "public.app-category.utilities"
            )
        ])

        let entry = fixture.service.snapshot().visibleApplications.first

        #expect(entry?.path == "/Applications/Utilities/App.app")
        #expect(entry?.category == "public.app-category.utilities")
    }
}

@Suite("别名")
struct LibraryServiceAliasTests {
    private func fixture() throws -> ServiceFixture {
        try ServiceFixture(records: [TestRecords.make("com.example.app", name: "Real Name")])
    }

    @Test("未设置别名时显示真实名称")
    func usesRealNameWithoutAlias() throws {
        let snapshot = try fixture().service.snapshot()

        #expect(snapshot.visibleApplications.first?.displayName == "Real Name")
    }

    @Test("设置别名后显示别名，真实名称仍然带在条目里")
    func aliasOverridesRealName() throws {
        let service = try fixture().service

        try service.setAlias("我的别名", for: "com.example.app")

        let entry = try #require(service.snapshot().visibleApplications.first)
        #expect(entry.displayName == "我的别名")
        // 详情面板要能说清这究竟是哪个应用，所以真实名称不能丢。
        #expect(entry.realName == "Real Name")
    }

    @Test("别名落盘，重启后还在")
    func aliasSurvivesRestart() throws {
        let fixture = try fixture()
        try fixture.service.setAlias("我的别名", for: "com.example.app")

        #expect(fixture.service.snapshot().visibleApplications.first?.displayName == "我的别名")
    }

    @Test("别名首尾空白被裁掉")
    func trimsAlias() throws {
        let service = try fixture().service

        try service.setAlias("  我的别名  ", for: "com.example.app")

        #expect(service.currentConfig.applications["com.example.app"]?.alias == "我的别名")
    }

    @Test("清除别名后恢复真实名称", arguments: [nil, "", "   "])
    func clearsAlias(alias: String?) throws {
        let service = try fixture().service
        try service.setAlias("我的别名", for: "com.example.app")

        try service.setAlias(alias, for: "com.example.app")

        // 空白输入与「清除」落到同一个状态：配置里没有别名。
        #expect(service.currentConfig.applications["com.example.app"]?.alias == nil)
        #expect(service.snapshot().visibleApplications.first?.displayName == "Real Name")
    }

    @Test("别名参与排序：改了名字，先后也跟着变")
    func sortingUsesAlias() throws {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.first", name: "AAA"),
            TestRecords.make("com.example.second", name: "ZZZ"),
        ])

        try fixture.service.setAlias("zzz 改名", for: "com.example.first")

        #expect(fixture.service.snapshot().visibleApplications.map(\.displayName) == ["ZZZ", "zzz 改名"])
    }

    @Test("给没出现在配置里的应用设别名，只建这一条记录")
    func aliasingUnknownIdentifierRecordsOnlyThatApplication() throws {
        let fixture = try ServiceFixture(records: [TestRecords.make("com.example.app", name: "App")])

        try fixture.service.setAlias("别名", for: "com.example.app")

        #expect(fixture.service.currentConfig.applications.count == 1)
        #expect(fixture.service.currentConfig.applications["com.example.app"]?.groupID == Group.ungroupedID)
    }
}

@Suite("隐藏")
struct LibraryServiceHiddenTests {
    private func fixture() throws -> ServiceFixture {
        try ServiceFixture(records: [
            TestRecords.make("com.example.keep", name: "Keep"),
            TestRecords.make("com.example.hide", name: "Hide"),
        ])
    }

    @Test("隐藏后它从覆盖层消失，但控制台里仍然看得到")
    func hidingRemovesFromOverlayOnly() throws {
        let service = try fixture().service

        try service.setHidden(true, for: "com.example.hide")

        let snapshot = service.snapshot()
        #expect(snapshot.visibleApplications.map(\.bundleIdentifier) == ["com.example.keep"])
        // 控制台读的是分组里的全部成员：隐藏的还得列出来，否则没法恢复它。
        let ungrouped = try #require(snapshot.groups.first { $0.group.isUngrouped })
        #expect(ungrouped.applications.map(\.bundleIdentifier)
            == ["com.example.hide", "com.example.keep"])
        #expect(ungrouped.visibleApplications.map(\.bundleIdentifier) == ["com.example.keep"])
        #expect(ungrouped.applications.first { $0.bundleIdentifier == "com.example.hide" }?.isHidden == true)
    }

    @Test("隐藏组内应用后，分组方块的缩略图也不含它")
    func groupingTilesExcludeHidden() throws {
        let fixture = try ServiceFixture(
            records: [
                TestRecords.make("com.example.first", name: "First"),
                TestRecords.make("com.example.second", name: "Second"),
            ],
            config: AppBoxConfig(
                groups: [.ungrouped, Group(id: "dev", name: "开发")],
                applications: ["com.example.first": ApplicationConfig(groupID: "dev")]
            )
        )
        let service = fixture.service
        try service.setHidden(true, for: "com.example.first")

        let dev = try #require(service.snapshot().groups.first { $0.group.id == "dev" })

        #expect(dev.applications.count == 1)
        #expect(dev.visibleApplications.isEmpty)
    }

    @Test("隐藏可以恢复")
    func hidingIsReversible() throws {
        let service = try fixture().service
        try service.setHidden(true, for: "com.example.hide")

        try service.setHidden(false, for: "com.example.hide")

        #expect(service.snapshot().visibleApplications.map(\.bundleIdentifier)
            == ["com.example.hide", "com.example.keep"])
    }

    @Test("隐藏落盘，重启后仍然隐藏")
    func hidingSurvivesRestart() throws {
        let fixture = try fixture()
        try fixture.service.setHidden(true, for: "com.example.hide")

        #expect(fixture.service.snapshot().visibleApplications.map(\.bundleIdentifier) == ["com.example.keep"])
    }

    @Test("隐藏不等于失效：应用还在磁盘上，就不会进失效列表")
    func hiddenApplicationIsNotMissing() throws {
        let service = try fixture().service

        try service.setHidden(true, for: "com.example.hide")

        #expect(service.snapshot().missing.isEmpty)
    }
}

@Suite("排序权重")
struct LibraryServiceOrderingTests {
    @Test("组内按权重排，没有权重的垫底而不是打头")
    func ordersByWeightWithUnnumberedLast() throws {
        let fixture = try ServiceFixture(
            records: [
                TestRecords.make("com.example.heavy", name: "AAA"),
                TestRecords.make("com.example.light", name: "ZZZ"),
                TestRecords.make("com.example.none", name: "MMM"),
            ],
            config: AppBoxConfig(
                applications: [
                    "com.example.heavy": ApplicationConfig(orderWeight: 10),
                    "com.example.light": ApplicationConfig(orderWeight: 5),
                ]
            )
        )

        let names = fixture.service.snapshot().visibleApplications.map(\.displayName)

        // 权重 5 的 ZZZ、权重 10 的 AAA，都没编号的 MMM 垫底——
        // 它是「还没排过队」的那个，不该插到排过队的前面。
        #expect(names == ["ZZZ", "AAA", "MMM"])
    }

    @Test("权重相同按显示名，名字也相同按 bundleID 兜底")
    func ordersTiedWeightsByNameThenIdentifier() throws {
        let fixture = try ServiceFixture(
            records: [
                TestRecords.make("com.example.b", name: "同名"),
                TestRecords.make("com.example.a", name: "同名"),
            ],
            config: AppBoxConfig(
                applications: [
                    "com.example.a": ApplicationConfig(orderWeight: 1),
                    "com.example.b": ApplicationConfig(orderWeight: 1),
                ]
            )
        )

        #expect(fixture.service.snapshot().visibleApplications.map(\.bundleIdentifier)
            == ["com.example.a", "com.example.b"])
    }

    @Test("重排之后新装的应用排在末尾，不会插进排好的队列")
    func newApplicationSortsLast() throws {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.first", name: "First"),
            TestRecords.make("com.example.second", name: "Second"),
        ])
        let service = fixture.service
        try service.reorder(groupID: Group.ungroupedID, to: ["com.example.second", "com.example.first"])

        fixture.scanner.setRecords([
            TestRecords.make("com.example.first", name: "First"),
            TestRecords.make("com.example.second", name: "Second"),
            TestRecords.make("com.example.znew", name: "Znew"),
        ])

        #expect(service.snapshot().visibleApplications.map(\.bundleIdentifier)
            == ["com.example.second", "com.example.first", "com.example.znew"])
    }

    @Test("重排只影响被重排的那一组")
    func reorderLeavesOtherGroupsAlone() throws {
        let fixture = try ServiceFixture(
            records: [
                TestRecords.make("com.example.first", name: "First"),
                TestRecords.make("com.example.second", name: "Second"),
            ],
            config: AppBoxConfig(
                groups: [.ungrouped, Group(id: "dev", name: "开发")],
                applications: ["com.example.first": ApplicationConfig(groupID: "dev")]
            )
        )
        let service = fixture.service

        try service.reorder(groupID: "dev", to: ["com.example.first"])

        let ungrouped = try #require(service.snapshot().groups.first { $0.group.isUngrouped })
        #expect(ungrouped.applications.map(\.bundleIdentifier) == ["com.example.second"])
    }
}

@Suite("锁定位置")
struct LibraryServiceLockTests {
    private func fixture() throws -> ServiceFixture {
        try ServiceFixture(records: [
            TestRecords.make("com.example.a", name: "A"),
            TestRecords.make("com.example.b", name: "B"),
            TestRecords.make("com.example.c", name: "C"),
        ])
    }

    @Test("锁定后，新装的应用排在它后面而不是把它挤走")
    func lockedApplicationKeepsItsSlot() throws {
        let fixture = try fixture()
        let service = fixture.service
        try service.setLocked(true, for: "com.example.b")
        #expect(service.snapshot().visibleApplications.map(\.bundleIdentifier)
            == ["com.example.a", "com.example.b", "com.example.c"])

        // 名字排在 B 前面的新应用：如果没锁定，它会被挤到第 3 位。
        fixture.scanner.setRecords([
            TestRecords.make("com.example.aa", name: "AA"),
            TestRecords.make("com.example.a", name: "A"),
            TestRecords.make("com.example.b", name: "B"),
            TestRecords.make("com.example.c", name: "C"),
        ])

        #expect(service.snapshot().visibleApplications.map(\.bundleIdentifier)
            == ["com.example.a", "com.example.b", "com.example.c", "com.example.aa"])
    }

    @Test("改名也不会把锁定应用挤走")
    func lockedApplicationSurvivesRenameOfNeighbour() throws {
        let service = try fixture().service
        try service.setLocked(true, for: "com.example.b")

        try service.setAlias("zzzz", for: "com.example.a")

        #expect(service.snapshot().visibleApplications.map(\.bundleIdentifier)
            == ["com.example.a", "com.example.b", "com.example.c"])
    }

    @Test("重排时锁定的那个原位不动，别人围着它换")
    func reorderKeepsLockedMemberInPlace() throws {
        let service = try fixture().service
        try service.setLocked(true, for: "com.example.b")

        // 把 B 拖到最前面的请求：锁定了就不认，它留在第 2 格，其余按请求的先后填。
        try service.reorder(groupID: Group.ungroupedID, to: ["com.example.b", "com.example.c", "com.example.a"])

        #expect(service.snapshot().visibleApplications.map(\.bundleIdentifier)
            == ["com.example.c", "com.example.b", "com.example.a"])
    }

    @Test("锁定的应用不能被移进别的分组")
    func lockedApplicationCannotBeMovedToAnotherGroup() throws {
        let fixture = try ServiceFixture(
            records: [TestRecords.make("com.example.a", name: "A")],
            config: AppBoxConfig(groups: [.ungrouped, Group(id: "dev", name: "开发")])
        )
        let service = fixture.service
        try service.setLocked(true, for: "com.example.a")

        #expect(throws: GroupError.applicationLocked("com.example.a")) {
            try service.move(bundleIdentifier: "com.example.a", toGroup: "dev")
        }
        #expect(service.currentConfig.applications["com.example.a"]?.groupID == Group.ungroupedID)
    }

    @Test("解锁之后又能动了")
    func unlockingRestoresDragging() throws {
        let service = try fixture().service
        try service.setLocked(true, for: "com.example.b")

        try service.setLocked(false, for: "com.example.b")
        try service.reorder(groupID: Group.ungroupedID, to: ["com.example.b", "com.example.a", "com.example.c"])

        #expect(service.snapshot().visibleApplications.map(\.bundleIdentifier)
            == ["com.example.b", "com.example.a", "com.example.c"])
    }

    @Test("锁定落盘，重启后仍然是锁定的")
    func lockingSurvivesRestart() throws {
        let fixture = try fixture()
        try fixture.service.setLocked(true, for: "com.example.b")

        #expect(fixture.service.currentConfig.applications["com.example.b"]?.locked == true)
        #expect(fixture.service.snapshot().visibleApplications.first { $0.bundleIdentifier == "com.example.b" }?.isLocked == true)
    }

    @Test("锁定时整组拿到明确编号，随后新装的都排在末尾")
    func lockingMaterializesTheWholeGroupOrder() throws {
        let fixture = try fixture()
        let service = fixture.service
        try service.setLocked(true, for: "com.example.b")

        let weights = service.currentConfig.applications.mapValues(\.orderWeight)
        #expect(weights == ["com.example.a": 1, "com.example.b": 2, "com.example.c": 3])
    }
}

@Suite("失效列表")
struct LibraryServiceMissingTests {
    private func config() -> AppBoxConfig {
        AppBoxConfig(
            groups: [.ungrouped, Group(id: "dev", name: "开发")],
            applications: [
                "com.example.gone": ApplicationConfig(
                    groupID: "dev",
                    alias: "走丢的那个",
                    lastKnownPath: "/Applications/Gone.app"
                )
            ]
        )
    }

    @Test("配置里有、磁盘上找不到的应用进失效列表")
    func listsConfiguredButMissingApplications() throws {
        let fixture = try ServiceFixture(
            records: [TestRecords.make("com.example.app", name: "App")],
            config: config()
        )

        let snapshot = fixture.service.snapshot()

        #expect(snapshot.missing.map(\.bundleIdentifier) == ["com.example.gone"])
        #expect(snapshot.missing.first?.groupID == "dev")
        #expect(snapshot.missing.first?.alias == "走丢的那个")
        #expect(snapshot.missing.first?.lastKnownPath == "/Applications/Gone.app")
    }

    @Test("失效的应用不出现在分组里，也不在覆盖层的任何位置")
    func missingApplicationsAreInvisible() throws {
        let fixture = try ServiceFixture(
            records: [TestRecords.make("com.example.app", name: "App")],
            config: config()
        )

        let snapshot = fixture.service.snapshot()

        #expect(snapshot.visibleApplications.map(\.bundleIdentifier) == ["com.example.app"])
        #expect(snapshot.groups.flatMap(\.applications).map(\.bundleIdentifier) == ["com.example.app"])
    }

    @Test("扫到的应用不会进失效列表")
    func presentApplicationsAreNotMissing() throws {
        let fixture = try ServiceFixture(
            records: [
                TestRecords.make("com.example.app", name: "App"),
                TestRecords.make("com.example.gone", name: "Gone"),
            ],
            config: config()
        )

        #expect(fixture.service.snapshot().missing.isEmpty)
    }

    @Test("失效列表按 bundleID 排序，先后不随扫描结果抖动")
    func missingListIsOrdered() throws {
        let fixture = try ServiceFixture(
            config: AppBoxConfig(applications: [
                "com.example.zebra": ApplicationConfig(),
                "com.example.alpha": ApplicationConfig(),
                "com.example.middle": ApplicationConfig(),
            ])
        )

        #expect(fixture.service.snapshot().missing.map(\.bundleIdentifier)
            == ["com.example.alpha", "com.example.middle", "com.example.zebra"])
    }

    @Test("记录路径时只在已有记录上写，不给没碰过的应用建记录")
    func recordingPathsLeavesUntrackedApplicationsAlone() throws {
        let fixture = try ServiceFixture(
            records: [
                TestRecords.make("com.example.tracked", name: "Tracked"),
                TestRecords.make("com.example.stranger", name: "Stranger"),
            ],
            config: AppBoxConfig(applications: ["com.example.tracked": ApplicationConfig()])
        )

        _ = fixture.service.snapshot(recordingPaths: true)

        #expect(fixture.service.currentConfig.applications.keys.sorted() == ["com.example.tracked"])
        #expect(fixture.service.currentConfig.applications["com.example.tracked"]?.lastKnownPath
            == "/Applications/Tracked.app")
    }

    @Test("记下路径之后应用不见了，失效列表说得出它最后在哪")
    func recordedPathEndsUpInTheMissingList() throws {
        let fixture = try ServiceFixture(
            records: [TestRecords.make("com.example.tracked", name: "Tracked")],
            config: AppBoxConfig(applications: ["com.example.tracked": ApplicationConfig()])
        )

        _ = fixture.service.snapshot(recordingPaths: true)
        fixture.scanner.setRecords([])

        #expect(fixture.service.snapshot().missing.first?.lastKnownPath == "/Applications/Tracked.app")
    }

    @Test("记录路径是幂等的：路径没变就不改配置")
    func recordingPathsIsIdempotent() throws {
        let fixture = try ServiceFixture(
            records: [TestRecords.make("com.example.tracked", name: "Tracked")],
            config: AppBoxConfig(applications: ["com.example.tracked": ApplicationConfig()])
        )
        _ = fixture.service.snapshot(recordingPaths: true)
        let after = fixture.service.currentConfig

        _ = fixture.service.snapshot(recordingPaths: true)

        #expect(fixture.service.currentConfig == after)
    }

    @Test("清理一条记录：别名、分组、隐藏一并消失，重启后仍然没有")
    func forgetRemovesTheWholeRecord() throws {
        let fixture = try ServiceFixture(config: config())
        let service = fixture.service

        try service.forget(bundleIdentifier: "com.example.gone")

        #expect(service.snapshot().missing.isEmpty)
        #expect(fixture.service.currentConfig.applications["com.example.gone"] == nil)
    }

    @Test("清理只删配置，别的应用的设置一个不动")
    func forgetLeavesOthersAlone() throws {
        let config = AppBoxConfig(applications: [
            "com.example.gone": ApplicationConfig(hidden: true),
            "com.example.keep": ApplicationConfig(alias: "留着", hidden: true),
        ])
        let fixture = try ServiceFixture(config: config)
        let service = fixture.service

        try service.forget(bundleIdentifier: "com.example.gone")

        #expect(service.currentConfig.applications["com.example.keep"]?.alias == "留着")
        #expect(service.currentConfig.applications["com.example.keep"]?.hidden == true)
    }

    @Test("清理一条不存在的记录不报错")
    func forgetIsIdempotent() throws {
        let service = try ServiceFixture().service

        try service.forget(bundleIdentifier: "com.example.never")
        try service.forget(bundleIdentifier: "com.example.never")

        #expect(service.currentConfig.applications.isEmpty)
    }
}

@Suite("删除分组与单应用设置")
struct LibraryServiceGroupDeletionTests {
    @Test("删除分组只改归属：别名、隐藏、锁定、权重都留着")
    func deletionKeepsApplicationSettings() throws {
        let fixture = try ServiceFixture(
            records: [
                TestRecords.make("com.example.first", name: "First"),
                TestRecords.make("com.example.second", name: "Second"),
            ],
            config: AppBoxConfig(
                groups: [.ungrouped, Group(id: "dev", name: "开发")],
                applications: [
                    "com.example.first": ApplicationConfig(
                        groupID: "dev",
                        orderWeight: 3,
                        alias: "一号",
                        hidden: true,
                        locked: true
                    ),
                    "com.example.second": ApplicationConfig(groupID: "dev"),
                ]
            )
        )
        let service = fixture.service

        try service.deleteGroup(id: "dev")

        let application = try #require(service.currentConfig.applications["com.example.first"])
        #expect(application.groupID == Group.ungroupedID)
        #expect(application.orderWeight == 3)
        #expect(application.alias == "一号")
        #expect(application.hidden)
        #expect(application.locked)
    }
}

@Suite("启动应用")
struct LibraryServiceLaunchTests {
    @Test("启动时传出的 bundleID 与点击的一致")
    func launchesClickedApplication() throws {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.first", name: "First"),
            TestRecords.make("com.example.second", name: "Second"),
        ])
        let clicked = try #require(
            fixture.service.snapshot().visibleApplications.first { $0.bundleIdentifier == "com.example.second" }
        )

        fixture.service.launch(clicked)

        #expect(fixture.launcher.launched.count == 1)
        #expect(fixture.launcher.launched.first?.bundleIdentifier == "com.example.second")
    }

    @Test("启动时带上该应用的路径，避免再次扫描")
    func launchCarriesPath() throws {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.app", name: "App", path: "/Applications/App.app")
        ])
        let entry = try #require(fixture.service.snapshot().visibleApplications.first)

        fixture.service.launch(entry)

        #expect(fixture.launcher.launched.first?.path == "/Applications/App.app")
    }
}
