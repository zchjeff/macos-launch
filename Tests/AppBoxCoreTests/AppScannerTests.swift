import Foundation
import Testing

@testable import AppBoxCore

@Suite("应用扫描")
struct AppScannerTests {
    @Test("扫描到一个 .app 包时，读出它的 bundleID、显示名、路径与类别")
    func readsBundleMetadata() throws {
        let tree = try AppTree()
        let bundle = try tree.app(
            "Safari.app",
            .valid([
                "CFBundleIdentifier": "com.apple.Safari",
                "CFBundleName": "Safari",
                "LSApplicationCategoryType": "public.app-category.productivity",
            ])
        )

        let records = AppScanner().scan(roots: [tree.scanRoot])

        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.bundleIdentifier == "com.apple.Safari")
        #expect(record.displayName == "Safari")
        #expect(record.path == bundle.path)
        #expect(record.category == "public.app-category.productivity")
        #expect(record.directory == .applications)
    }

    @Test("CFBundleDisplayName 优先于 CFBundleName")
    func prefersDisplayNameOverName() throws {
        let tree = try AppTree()
        try tree.app(
            "Xcode.app",
            .valid([
                "CFBundleIdentifier": "com.apple.dt.Xcode",
                "CFBundleName": "Xcode",
                "CFBundleDisplayName": "Xcode 测试版",
            ])
        )

        let record = try #require(AppScanner().scan(roots: [tree.scanRoot]).first)
        #expect(record.displayName == "Xcode 测试版")
    }

    @Test("CFBundleName 缺失时，回退用去掉 .app 的文件名")
    func fallsBackToFileNameWhenNameMissing() throws {
        let tree = try AppTree()
        try tree.app("Some Tool.app", .valid(["CFBundleIdentifier": "com.example.sometool"]))

        let record = try #require(AppScanner().scan(roots: [tree.scanRoot]).first)
        #expect(record.displayName == "Some Tool")
    }

    @Test("空的 CFBundleDisplayName 不算数，继续往后回退")
    func ignoresEmptyDisplayName() throws {
        let tree = try AppTree()
        try tree.app(
            "Foo.app",
            .valid([
                "CFBundleIdentifier": "com.example.foo",
                "CFBundleDisplayName": "",
                "CFBundleName": "Foo Bar",
            ])
        )

        let record = try #require(AppScanner().scan(roots: [tree.scanRoot]).first)
        #expect(record.displayName == "Foo Bar")
    }

    @Test("zh-Hans 本地化名收进 localizedName：英文名 WeChat 也认得「微信」")
    func readsChineseLocalizedName() throws {
        let tree = try AppTree()
        let bundle = try tree.app(
            "WeChat.app",
            .valid(["CFBundleIdentifier": "com.tencent.xinWeChat", "CFBundleDisplayName": "WeChat"])
        )
        try tree.localizedStrings(["CFBundleDisplayName": "微信", "CFBundleName": "微信"], in: bundle)

        let record = try #require(AppScanner().scan(roots: [tree.scanRoot]).first)
        #expect(record.displayName == "WeChat")
        #expect(record.localizedName == "微信")
    }

    @Test("没有中文本地化包时 localizedName 为 nil；与显示名相同的也不算")
    func localizedNameIsNilWithoutChineseBundle() throws {
        let tree = try AppTree()
        try tree.app("Plain.app", .valid(["CFBundleIdentifier": "com.example.plain"]))
        #expect(AppScanner().scan(roots: [tree.scanRoot]).first?.localizedName == nil)

        let same = try tree.app(
            "Same.app",
            .valid(["CFBundleIdentifier": "com.example.same", "CFBundleDisplayName": "Same"])
        )
        try tree.localizedStrings(["CFBundleDisplayName": "Same"], in: same)
        let records = AppScanner().scan(roots: [tree.scanRoot])
        #expect(records.first { $0.bundleIdentifier == "com.example.same" }?.localizedName == nil)
    }

    @Test("没有 CFBundleIdentifier 时，退化成绝对路径作为主键")
    func fallsBackToPathAsIdentifier() throws {
        let tree = try AppTree()
        let bundle = try tree.app("Anonymous.app", .valid(["CFBundleName": "Anonymous"]))

        let record = try #require(AppScanner().scan(roots: [tree.scanRoot]).first)
        #expect(record.bundleIdentifier == bundle.path)
    }

    @Test("CFBundleIdentifier 是空字符串时，同样退化成绝对路径")
    func treatsEmptyIdentifierAsMissing() throws {
        let tree = try AppTree()
        let bundle = try tree.app("Blank.app", .valid(["CFBundleIdentifier": ""]))

        let record = try #require(AppScanner().scan(roots: [tree.scanRoot]).first)
        #expect(record.bundleIdentifier == bundle.path)
        #expect(record.displayName == "Blank")
    }
}

@Suite("同一 bundleID 的去重优先级")
struct AppScannerDeduplicationTests {
    private let info: AppTree.InfoPlist = .valid([
        "CFBundleIdentifier": "com.example.duplicated",
        "CFBundleName": "Duplicated",
    ])

    /// 建三个并列的扫描根，各放一份同名应用，返回根与它们的实际路径。
    private func threeCopies(_ tree: AppTree) throws -> (applications: ScanRoot, system: ScanRoot, user: ScanRoot) {
        let applications = try tree.makeRoot("Applications", .applications)
        let system = try tree.makeRoot("SystemApplications", .systemApplications)
        let user = try tree.makeRoot("UserApplications", .userApplications)
        try tree.app(in: applications.url, "Duplicated.app", info)
        try tree.app(in: system.url, "Duplicated.app", info)
        try tree.app(in: user.url, "Duplicated.app", info)
        return (applications, system, user)
    }

    @Test("三处都有时只保留一份，且是 /Applications 里那份")
    func applicationsWinsOverAll() throws {
        let tree = try AppTree()
        let roots = try threeCopies(tree)

        let records = AppScanner().scan(roots: [roots.applications, roots.system, roots.user])

        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.path == roots.applications.url.appendingPathComponent("Duplicated.app").path)
        #expect(record.directory == .applications)
    }

    @Test("传入顺序不影响结果——优先级来自扫描根声明的目录类型，不是数组顺序")
    func priorityIsIndependentOfArgumentOrder() throws {
        let tree = try AppTree()
        let roots = try threeCopies(tree)

        let records = AppScanner().scan(roots: [roots.user, roots.system, roots.applications])

        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.directory == .applications)
    }

    @Test("/System/Applications 优先于 ~/Applications")
    func systemWinsOverUser() throws {
        let tree = try AppTree()
        let roots = try threeCopies(tree)

        let records = AppScanner().scan(roots: [roots.user, roots.system])

        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.directory == .systemApplications)
    }

    @Test("同一个扫描根里出现两份时，取路径更浅的那份，结果稳定")
    func shallowerCopyWinsWithinOneRoot() throws {
        let tree = try AppTree()
        try tree.app("Duplicated.app", info)
        try tree.app("Utilities/Duplicated.app", info)

        let records = AppScanner().scan(roots: [tree.scanRoot])

        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.path == tree.root.appendingPathComponent("Duplicated.app").path)
    }

    @Test("bundleID 不同的应用互不影响")
    func distinctIdentifiersCoexist() throws {
        let tree = try AppTree()
        try tree.app("One.app", .valid(["CFBundleIdentifier": "com.example.one"]))
        try tree.app("Two.app", .valid(["CFBundleIdentifier": "com.example.two"]))

        let records = AppScanner().scan(roots: [tree.scanRoot])

        #expect(Set(records.map(\.bundleIdentifier)) == ["com.example.one", "com.example.two"])
    }
}

@Suite("扫描范围与嵌套规则")
struct AppScannerNestingTests {
    @Test("扫描根的一级子目录里的应用会被发现")
    func findsAppsInImmediateSubdirectory() throws {
        let tree = try AppTree()
        try tree.app("Utilities/Terminal.app", .valid(["CFBundleIdentifier": "com.apple.Terminal"]))

        let records = AppScanner().scan(roots: [tree.scanRoot])

        #expect(records.count == 1)
        #expect(records.first?.bundleIdentifier == "com.apple.Terminal")
    }

    @Test("只扫一级子目录，更深层的应用不进入清单")
    func ignoresAppsDeeperThanOneLevel() throws {
        let tree = try AppTree()
        try tree.app("Nested/Deeper/Buried.app", .valid(["CFBundleIdentifier": "com.example.buried"]))

        #expect(AppScanner().scan(roots: [tree.scanRoot]).isEmpty)
    }

    @Test("应用包内部的嵌套 .app 不会被当成独立应用")
    func ignoresAppsNestedInsideAnotherApp() throws {
        let tree = try AppTree()
        let host = try tree.app("Host.app", .valid(["CFBundleIdentifier": "com.example.host"]))
        // 模拟登录项 Helper：位于 Host.app/Contents/Library/LoginItems/ 下。
        try tree.app(
            in: host.appendingPathComponent("Contents"),
            "Library/LoginItems/Helper.app",
            .valid(["CFBundleIdentifier": "com.example.host.helper"])
        )

        let records = AppScanner().scan(roots: [tree.scanRoot])

        #expect(records.map(\.bundleIdentifier) == ["com.example.host"])
    }

    @Test("扫描根里的普通文件被忽略")
    func ignoresPlainFiles() throws {
        let tree = try AppTree()
        try tree.file("readme.txt", contents: "hello")
        try tree.file(".DS_Store")
        try tree.app("Real.app", .valid(["CFBundleIdentifier": "com.example.real"]))

        let records = AppScanner().scan(roots: [tree.scanRoot])

        #expect(records.map(\.bundleIdentifier) == ["com.example.real"])
    }

    @Test("不以 .app 结尾的目录不被当成应用")
    func ignoresDirectoriesNotEndingInAppExtension() throws {
        let tree = try AppTree()
        try tree.directory("Some Folder.app.backup")
        try tree.directory("Frameworks")

        #expect(AppScanner().scan(roots: [tree.scanRoot]).isEmpty)
    }

    @Test("不存在的扫描根被跳过，不报错也不影响其它根")
    func skipsMissingRoot() throws {
        let tree = try AppTree()
        try tree.app("Present.app", .valid(["CFBundleIdentifier": "com.example.present"]))
        let missing = ScanRoot(
            url: tree.root.appendingPathComponent("DoesNotExist", isDirectory: true),
            directory: .systemApplications
        )

        let records = AppScanner().scan(roots: [missing, tree.scanRoot])

        #expect(records.map(\.bundleIdentifier) == ["com.example.present"])
    }

    @Test("空扫描根返回空清单")
    func emptyRootYieldsNothing() throws {
        let tree = try AppTree()

        #expect(AppScanner().scan(roots: [tree.scanRoot]).isEmpty)
    }
}

@Suite("Info.plist 缺失或损坏")
struct AppScannerBrokenPlistTests {
    // 这类目录在访达里仍然可见，所以照样列进清单，只是没有元数据可用：
    // 主键退化成路径、显示名退化成文件名。悄悄藏掉一个用户看得见的应用更糟。

    @Test("Info.plist 缺失时，仍列出该应用，主键为路径、显示名为文件名")
    func listsAppWithMissingPlist() throws {
        let tree = try AppTree()
        let bundle = try tree.app("Nameless.app", .missing)

        let record = try #require(AppScanner().scan(roots: [tree.scanRoot]).first)

        #expect(record.bundleIdentifier == bundle.path)
        #expect(record.displayName == "Nameless")
        #expect(record.category == nil)
    }

    @Test("Info.plist 内容损坏时，同样按无元数据处理")
    func listsAppWithCorruptPlist() throws {
        let tree = try AppTree()
        let bundle = try tree.app("Broken.app", .corrupt)

        let record = try #require(AppScanner().scan(roots: [tree.scanRoot]).first)

        #expect(record.bundleIdentifier == bundle.path)
        #expect(record.displayName == "Broken")
    }

    @Test("损坏的应用与正常应用能共存，各自独立成条")
    func brokenAndHealthyCoexist() throws {
        let tree = try AppTree()
        try tree.app("Healthy.app", .valid(["CFBundleIdentifier": "com.example.healthy"]))
        let broken = try tree.app("Broken.app", .corrupt)

        let records = AppScanner().scan(roots: [tree.scanRoot])

        #expect(records.count == 2)
        #expect(Set(records.map(\.bundleIdentifier)) == ["com.example.healthy", broken.path])
    }

    @Test("Info.plist 不是字典（合法 plist 但类型不对）时，也按无元数据处理")
    func treatsNonDictionaryPlistAsMissing() throws {
        let tree = try AppTree()
        let bundle = try tree.app("Weird.app", .missing)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["not", "a", "dictionary"],
            format: .xml,
            options: 0
        )
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))

        let record = try #require(AppScanner().scan(roots: [tree.scanRoot]).first)

        #expect(record.bundleIdentifier == bundle.path)
        #expect(record.displayName == "Weird")
    }
}
