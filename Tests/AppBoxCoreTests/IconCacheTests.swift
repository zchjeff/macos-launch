import Foundation
import Testing

@testable import AppBoxCore

/// 记录调用次数与参数，用来断言"命中缓存时不再渲染"。
final class FakeIconRenderer: IconRendering, @unchecked Sendable {
    private let lock = NSLock()
    private var _requestedPaths: [String] = []
    private var _pngData: Data?

    init(pngData: Data? = Data("fake-png-bytes".utf8)) {
        _pngData = pngData
    }

    func pngData(forApplicationAt path: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        _requestedPaths.append(path)
        return _pngData
    }

    var requestedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _requestedPaths
    }

    var callCount: Int { requestedPaths.count }
}

@Suite("图标缓存")
struct IconCacheTests {
    private func makeCache(_ tree: AppTree) -> IconCache {
        IconCache(directory: tree.root.appendingPathComponent("icons", isDirectory: true))
    }

    private func makeRecord(for bundle: URL, bundleIdentifier: String = "com.example.app") -> AppRecord {
        AppRecord(
            bundleIdentifier: bundleIdentifier,
            displayName: "App",
            path: bundle.path,
            category: nil,
            directory: .applications
        )
    }

    @Test("未命中缓存时渲染一次，并把 PNG 写到磁盘")
    func rendersAndWritesOnMiss() throws {
        let tree = try AppTree()
        let bundle = try tree.app("App.app", .valid(["CFBundleIdentifier": "com.example.app"]))
        let renderer = FakeIconRenderer()

        let url = try #require(makeCache(tree).iconURL(for: makeRecord(for: bundle), renderer: renderer))

        #expect(renderer.callCount == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url) == Data("fake-png-bytes".utf8))
    }

    @Test("缓存文件落在指定目录下，且扩展名是 png")
    func cacheFileLivesInConfiguredDirectory() throws {
        let tree = try AppTree()
        let bundle = try tree.app("App.app", .valid(["CFBundleIdentifier": "com.example.app"]))

        let url = try #require(makeCache(tree).iconURL(for: makeRecord(for: bundle), renderer: FakeIconRenderer()))

        #expect(url.deletingLastPathComponent().lastPathComponent == "icons")
        #expect(url.pathExtension == "png")
    }

    @Test("二次调用命中缓存，不再渲染")
    func secondCallHitsCache() throws {
        let tree = try AppTree()
        let bundle = try tree.app("App.app", .valid(["CFBundleIdentifier": "com.example.app"]))
        let cache = makeCache(tree)
        let record = makeRecord(for: bundle)
        let first = FakeIconRenderer()
        let second = FakeIconRenderer()

        let firstURL = try #require(cache.iconURL(for: record, renderer: first))
        let secondURL = try #require(cache.iconURL(for: record, renderer: second))

        #expect(first.callCount == 1)
        #expect(second.callCount == 0)
        #expect(firstURL == secondURL)
    }

    @Test("应用包修改时间变化后缓存失效，重新渲染")
    func cacheInvalidatesWhenBundleModificationDateChanges() throws {
        let tree = try AppTree()
        let bundle = try tree.app("App.app", .valid(["CFBundleIdentifier": "com.example.app"]))
        let cache = makeCache(tree)
        let record = makeRecord(for: bundle)

        let before = try #require(cache.iconURL(for: record, renderer: FakeIconRenderer()))

        let later = Date().addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: bundle.path)

        let after = FakeIconRenderer()
        let afterURL = try #require(cache.iconURL(for: record, renderer: after))

        #expect(after.callCount == 1)
        #expect(afterURL != before)
    }

    @Test("渲染失败时返回 nil，且不留下缓存文件")
    func returnsNilWhenRenderingFails() throws {
        let tree = try AppTree()
        let bundle = try tree.app("App.app", .valid(["CFBundleIdentifier": "com.example.app"]))
        let renderer = FakeIconRenderer(pngData: nil)

        let url = makeCache(tree).iconURL(for: makeRecord(for: bundle), renderer: renderer)

        #expect(url == nil)
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: tree.root.appendingPathComponent("icons").path
        )
        #expect(leftovers.isEmpty)
    }

    @Test("不同 bundleID 用不同的缓存文件，互不覆盖")
    func distinctIdentifiersGetDistinctFiles() throws {
        let tree = try AppTree()
        let first = try tree.app("First.app", .valid(["CFBundleIdentifier": "com.example.first"]))
        let second = try tree.app("Second.app", .valid(["CFBundleIdentifier": "com.example.second"]))
        let cache = makeCache(tree)

        let firstURL = try #require(
            cache.iconURL(for: makeRecord(for: first, bundleIdentifier: "com.example.first"), renderer: FakeIconRenderer())
        )
        let secondURL = try #require(
            cache.iconURL(for: makeRecord(for: second, bundleIdentifier: "com.example.second"), renderer: FakeIconRenderer())
        )

        #expect(firstURL != secondURL)
    }

    @Test("主键是路径（无 bundleID 的应用）时也能缓存，且不同路径不互相覆盖")
    func pathKeyedRecordsDoNotCollide() throws {
        let tree = try AppTree()
        try tree.app("First.app", .missing)
        try tree.app("Second.app", .missing)
        let cache = makeCache(tree)

        // 走真实扫描：没有 Info.plist 的应用，主键就是它的绝对路径。
        let records = AppScanner().scan(roots: [tree.scanRoot])
        #expect(records.count == 2)
        let urls = try records.map { record in
            try #require(cache.iconURL(for: record, renderer: FakeIconRenderer()))
        }

        #expect(Set(urls.map(\.path)).count == 2)
        for url in urls {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("应用包已被删除时，渲染器拿不到数据，返回 nil")
    func returnsNilWhenBundleIsGone() throws {
        let tree = try AppTree()
        let bundle = try tree.app("Gone.app", .valid(["CFBundleIdentifier": "com.example.gone"]))
        let record = makeRecord(for: bundle)
        try FileManager.default.removeItem(at: bundle)

        #expect(makeCache(tree).iconURL(for: record, renderer: FakeIconRenderer()) == nil)
    }
}
