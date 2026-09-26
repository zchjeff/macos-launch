import Foundation
import Testing

@testable import AppBoxCore

@Suite("快照组装")
struct LibraryServiceSnapshotTests {
    @Test("快照包含扫描到的每个应用，显示名用真实名称")
    func snapshotCarriesScannedApplications() {
        let scanner = FakeAppScanner(records: [
            TestRecords.make("com.example.beta", name: "Beta"),
            TestRecords.make("com.example.alpha", name: "Alpha"),
        ])
        let service = LibraryService(scanner: scanner, icons: FakeIconProvider(), launcher: FakeLauncher())

        let snapshot = service.snapshot()

        #expect(snapshot.applications.map(\.bundleIdentifier) == ["com.example.alpha", "com.example.beta"])
        #expect(snapshot.applications.map(\.displayName) == ["Alpha", "Beta"])
    }

    @Test("快照按显示名排序，而不是按扫描返回的顺序")
    func snapshotSortsByDisplayName() {
        let scanner = FakeAppScanner(records: [
            TestRecords.make("com.example.c", name: "Cherry"),
            TestRecords.make("com.example.a", name: "apple"),
            TestRecords.make("com.example.b", name: "Banana"),
        ])
        let service = LibraryService(scanner: scanner, icons: FakeIconProvider(), launcher: FakeLauncher())

        let names = service.snapshot().applications.map(\.displayName)

        // localizedStandardCompare：大小写不敏感，所以 apple 排在 Banana 前。
        #expect(names == ["apple", "Banana", "Cherry"])
    }

    @Test("每个应用都向图标提供者问过图标，路径写进条目")
    func snapshotResolvesIcons() {
        let scanner = FakeAppScanner(records: [TestRecords.make("com.example.app", name: "App")])
        let icons = FakeIconProvider()
        let service = LibraryService(scanner: scanner, icons: icons, launcher: FakeLauncher())

        let entry = service.snapshot().applications.first

        #expect(icons.requestedIdentifiers == ["com.example.app"])
        #expect(entry?.iconCachePath == "/tmp/icons/com.example.app.png")
    }

    @Test("图标拿不到时条目仍然存在，图标路径为空")
    func snapshotToleratesMissingIcons() {
        let scanner = FakeAppScanner(records: [TestRecords.make("com.example.app", name: "App")])
        let service = LibraryService(scanner: scanner, icons: EmptyIconProvider(), launcher: FakeLauncher())

        let entry = service.snapshot().applications.first

        #expect(entry?.bundleIdentifier == "com.example.app")
        #expect(entry?.iconCachePath == nil)
    }

    @Test("没有扫描到任何应用时，快照是空的而不是崩掉")
    func emptyScanYieldsEmptySnapshot() {
        let service = LibraryService(scanner: FakeAppScanner(), icons: FakeIconProvider(), launcher: FakeLauncher())

        #expect(service.snapshot().applications.isEmpty)
    }

    @Test("路径与类别原样带进条目，供后续切片使用")
    func snapshotCarriesPathAndCategory() {
        let scanner = FakeAppScanner(records: [
            TestRecords.make(
                "com.example.app",
                name: "App",
                path: "/Applications/Utilities/App.app",
                category: "public.app-category.utilities"
            )
        ])
        let service = LibraryService(scanner: scanner, icons: FakeIconProvider(), launcher: FakeLauncher())

        let entry = service.snapshot().applications.first

        #expect(entry?.path == "/Applications/Utilities/App.app")
        #expect(entry?.category == "public.app-category.utilities")
    }
}

@Suite("别名与隐藏")
struct LibraryServiceOverrideTests {
    private func service(_ records: [AppRecord]) -> LibraryService {
        LibraryService(
            scanner: FakeAppScanner(records: records),
            icons: FakeIconProvider(),
            launcher: FakeLauncher()
        )
    }

    @Test("未设置别名时显示应用真实名称")
    func usesRealNameWithoutAlias() {
        let subject = service([TestRecords.make("com.example.app", name: "Real Name")])

        let snapshot = subject.snapshot()

        #expect(snapshot.applications.first?.displayName == "Real Name")
    }

    @Test("设置了别名时显示别名")
    func aliasOverridesRealName() {
        let subject = service([TestRecords.make("com.example.app", name: "Real Name")])

        let snapshot = subject.snapshot(aliases: ["com.example.app": "我的别名"])

        #expect(snapshot.applications.first?.displayName == "我的别名")
    }

    @Test("别名生效后按别名重新排序")
    func sortingUsesAlias() {
        let subject = service([
            TestRecords.make("com.example.first", name: "AAA"),
            TestRecords.make("com.example.second", name: "ZZZ"),
        ])

        let names = subject.snapshot(aliases: ["com.example.first": "zzz 改名"]).applications.map(\.displayName)

        #expect(names == ["ZZZ", "zzz 改名"])
    }

    @Test("空别名不算数，回退到真实名称")
    func emptyAliasFallsBackToRealName() {
        let subject = service([TestRecords.make("com.example.app", name: "Real Name")])

        let snapshot = subject.snapshot(aliases: ["com.example.app": ""])

        #expect(snapshot.applications.first?.displayName == "Real Name")
    }

    @Test("给不存在的 bundleID 设别名不会凭空造出条目")
    func aliasForUnknownIdentifierAddsNothing() {
        let subject = service([TestRecords.make("com.example.app", name: "App")])

        let snapshot = subject.snapshot(aliases: ["com.example.ghost": "幽灵"])

        #expect(snapshot.applications.map(\.bundleIdentifier) == ["com.example.app"])
    }

    @Test("隐藏的应用不进快照")
    func hiddenApplicationsAreExcluded() {
        let subject = service([
            TestRecords.make("com.example.keep", name: "Keep"),
            TestRecords.make("com.example.hide", name: "Hide"),
        ])

        let snapshot = subject.snapshot(hidden: ["com.example.hide"])

        #expect(snapshot.applications.map(\.bundleIdentifier) == ["com.example.keep"])
    }

    @Test("隐藏不存在的 bundleID 不报错")
    func hidingUnknownIdentifierIsHarmless() {
        let subject = service([TestRecords.make("com.example.app", name: "App")])

        let snapshot = subject.snapshot(hidden: ["com.example.ghost"])

        #expect(snapshot.applications.count == 1)
    }
}

@Suite("启动应用")
struct LibraryServiceLaunchTests {
    private func service(_ records: [AppRecord], launcher: FakeLauncher) -> LibraryService {
        LibraryService(
            scanner: FakeAppScanner(records: records),
            icons: FakeIconProvider(),
            launcher: launcher
        )
    }

    @Test("启动时传出的 bundleID 与点击的一致")
    func launchesClickedApplication() throws {
        let launcher = FakeLauncher()
        let subject = service(
            [
                TestRecords.make("com.example.first", name: "First"),
                TestRecords.make("com.example.second", name: "Second"),
            ],
            launcher: launcher
        )
        let clicked = try #require(
            subject.snapshot().applications.first { $0.bundleIdentifier == "com.example.second" }
        )

        subject.launch(clicked)

        #expect(launcher.launched.count == 1)
        #expect(launcher.launched.first?.bundleIdentifier == "com.example.second")
    }

    @Test("启动时带上该应用的路径，避免再次扫描")
    func launchCarriesPath() throws {
        let launcher = FakeLauncher()
        let subject = service(
            [TestRecords.make("com.example.app", name: "App", path: "/Applications/App.app")],
            launcher: launcher
        )
        let entry = try #require(subject.snapshot().applications.first)

        subject.launch(entry)

        #expect(launcher.launched.first?.path == "/Applications/App.app")
    }
}
