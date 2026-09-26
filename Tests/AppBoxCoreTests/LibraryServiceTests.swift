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

        let applications = fixture.service.snapshot().allApplications

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

        let names = fixture.service.snapshot().allApplications.map(\.displayName)

        // localizedStandardCompare：大小写不敏感，所以 apple 排在 Banana 前。
        #expect(names == ["apple", "Banana", "Cherry"])
    }

    @Test("每个应用都向图标提供者问过图标，路径写进条目")
    func snapshotResolvesIcons() throws {
        let fixture = try ServiceFixture(records: [TestRecords.make("com.example.app", name: "App")])

        let entry = fixture.service.snapshot().allApplications.first

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

        let entry = service.snapshot().allApplications.first

        #expect(entry?.bundleIdentifier == "com.example.app")
        #expect(entry?.iconCachePath == nil)
    }

    @Test("没有扫描到任何应用时，快照只有空分组而不是崩掉")
    func emptyScanYieldsEmptySnapshot() throws {
        let fixture = try ServiceFixture()

        let snapshot = fixture.service.snapshot()

        #expect(snapshot.allApplications.isEmpty)
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

        let entry = fixture.service.snapshot().allApplications.first

        #expect(entry?.path == "/Applications/Utilities/App.app")
        #expect(entry?.category == "public.app-category.utilities")
    }
}

@Suite("别名与隐藏")
struct LibraryServiceOverrideTests {
    @Test("未设置别名时显示应用真实名称")
    func usesRealNameWithoutAlias() throws {
        let fixture = try ServiceFixture(records: [TestRecords.make("com.example.app", name: "Real Name")])

        let snapshot = fixture.service.snapshot()

        #expect(snapshot.allApplications.first?.displayName == "Real Name")
    }

    @Test("设置了别名时显示别名")
    func aliasOverridesRealName() throws {
        let fixture = try ServiceFixture(records: [TestRecords.make("com.example.app", name: "Real Name")])

        let snapshot = fixture.service.snapshot(aliases: ["com.example.app": "我的别名"])

        #expect(snapshot.allApplications.first?.displayName == "我的别名")
    }

    @Test("别名生效后按别名重新排序")
    func sortingUsesAlias() throws {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.first", name: "AAA"),
            TestRecords.make("com.example.second", name: "ZZZ"),
        ])

        let names = fixture.service
            .snapshot(aliases: ["com.example.first": "zzz 改名"])
            .allApplications.map(\.displayName)

        #expect(names == ["ZZZ", "zzz 改名"])
    }

    @Test("空别名不算数，回退到真实名称")
    func emptyAliasFallsBackToRealName() throws {
        let fixture = try ServiceFixture(records: [TestRecords.make("com.example.app", name: "Real Name")])

        let snapshot = fixture.service.snapshot(aliases: ["com.example.app": ""])

        #expect(snapshot.allApplications.first?.displayName == "Real Name")
    }

    @Test("给不存在的 bundleID 设别名不会凭空造出条目")
    func aliasForUnknownIdentifierAddsNothing() throws {
        let fixture = try ServiceFixture(records: [TestRecords.make("com.example.app", name: "App")])

        let snapshot = fixture.service.snapshot(aliases: ["com.example.ghost": "幽灵"])

        #expect(snapshot.allApplications.map(\.bundleIdentifier) == ["com.example.app"])
    }

    @Test("隐藏的应用不进快照")
    func hiddenApplicationsAreExcluded() throws {
        let fixture = try ServiceFixture(records: [
            TestRecords.make("com.example.keep", name: "Keep"),
            TestRecords.make("com.example.hide", name: "Hide"),
        ])

        let snapshot = fixture.service.snapshot(hidden: ["com.example.hide"])

        #expect(snapshot.allApplications.map(\.bundleIdentifier) == ["com.example.keep"])
    }

    @Test("隐藏不存在的 bundleID 不报错")
    func hidingUnknownIdentifierIsHarmless() throws {
        let fixture = try ServiceFixture(records: [TestRecords.make("com.example.app", name: "App")])

        let snapshot = fixture.service.snapshot(hidden: ["com.example.ghost"])

        #expect(snapshot.allApplications.count == 1)
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
            fixture.service.snapshot().allApplications.first { $0.bundleIdentifier == "com.example.second" }
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
        let entry = try #require(fixture.service.snapshot().allApplications.first)

        fixture.service.launch(entry)

        #expect(fixture.launcher.launched.first?.path == "/Applications/App.app")
    }
}
