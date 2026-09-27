import Foundation

@testable import AppBoxCore

/// 喂固定清单的假扫描器，让 `LibraryService` 的组装逻辑脱离文件系统单独受测。
final class FakeAppScanner: AppScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [AppRecord]
    private var _scanCount = 0

    init(records: [AppRecord] = []) {
        _records = records
    }

    func scan() -> [AppRecord] {
        lock.lock()
        defer { lock.unlock() }
        _scanCount += 1
        return _records
    }

    var scanCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _scanCount
    }

    func setRecords(_ records: [AppRecord]) {
        lock.lock()
        defer { lock.unlock() }
        _records = records
    }
}

/// 把主键映射成固定路径，并记录被问过哪些应用。
final class FakeIconProvider: IconProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _requested: [String] = []

    func iconURL(for record: AppRecord) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        _requested.append(record.bundleIdentifier)
        return URL(fileURLWithPath: "/tmp/icons/\(record.bundleIdentifier).png")
    }

    var requestedIdentifiers: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _requested
    }
}

/// 没有图标的提供者，用来验证"图标缺失不影响快照组装"。
final class EmptyIconProvider: IconProviding, @unchecked Sendable {
    func iconURL(for record: AppRecord) -> URL? { nil }
}

/// 记录启动调用，供断言"被启动的 bundleID 与点击的一致"。
final class FakeLauncher: Launching, @unchecked Sendable {
    private let lock = NSLock()
    private var _launched: [(bundleIdentifier: String, path: String)] = []

    func launch(bundleIdentifier: String, path: String) {
        lock.lock()
        defer { lock.unlock() }
        _launched.append((bundleIdentifier, path))
    }

    var launched: [(bundleIdentifier: String, path: String)] {
        lock.lock()
        defer { lock.unlock() }
        return _launched
    }
}

/// 记录开关调用的假登录项端口；`failOnSet` 用来模拟系统拒绝注册的场合。
final class FakeLoginItem: LoginItemControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: Bool
    private var _calls: [Bool] = []
    var failOnSet = false

    init(status: Bool = false) {
        _status = status
    }

    var status: Bool {
        lock.withLock { _status }
    }

    var calls: [Bool] {
        lock.withLock { _calls }
    }

    func setEnabled(_ enabled: Bool) throws {
        let fail = lock.withLock { () -> Bool in
            if failOnSet { return true }
            _status = enabled
            _calls.append(enabled)
            return false
        }
        if fail {
            throw NSError(domain: "FakeLoginItem", code: 1, userInfo: [NSLocalizedDescriptionKey: "系统拒绝注册"])
        }
    }
}

/// 手动触发的假监听：测试想什么时候报「目录变了」就什么时候报。
final class FakeWatcher: Watching, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?

    func start(onChange: @escaping @Sendable () -> Void) {
        lock.withLock { handler = onChange }
    }

    func stop() {
        lock.withLock { handler = nil }
    }

    var isWatching: Bool {
        lock.withLock { handler != nil }
    }

    /// 模拟一次目录变更事件。线程与真实实现一致：不保证在主线程。
    func fire() {
        let handler = lock.withLock { self.handler }
        handler?()
    }
}

enum TestRecords {
    static func make(
        _ bundleIdentifier: String,
        name: String,
        path: String? = nil,
        category: String? = nil,
        directory: ApplicationDirectory = .applications
    ) -> AppRecord {
        AppRecord(
            bundleIdentifier: bundleIdentifier,
            displayName: name,
            path: path ?? "/Applications/\(name).app",
            category: category,
            directory: directory
        )
    }
}

/// 渲染就绪的那一层。给不经过扫描、只关心投影的测试用。
enum TestEntries {
    static func make(
        _ bundleIdentifier: String,
        name: String,
        category: String? = nil,
        alias: String? = nil,
        isHidden: Bool = false
    ) -> ApplicationEntry {
        ApplicationEntry(
            bundleIdentifier: bundleIdentifier,
            realName: name,
            alias: alias,
            path: "/Applications/\(name).app",
            category: category,
            iconCachePath: nil,
            isHidden: isHidden,
            isLocked: false
        )
    }
}

/// 装配一个用假端口、真临时目录的 `LibraryService`。
///
/// 配置走真实的 `AppBoxConfigStore` 指向临时目录——分组是要落盘的东西，
/// 用内存假实现就等于把「改完重启还在不在」这条完全跳过。
///
/// `service` 每次访问都新建一个服务并从磁盘重读配置，所以它天然模拟了「重启」：
/// 上一次改动如果没真正落盘，下一次访问就看不见。
final class ServiceFixture {
    let store: AppBoxConfigStore
    let scanner: FakeAppScanner
    let icons: FakeIconProvider
    let launcher: FakeLauncher
    private let directory: TempDirectory

    init(records: [AppRecord] = [], config: AppBoxConfig = AppBoxConfig(), writesConfig: Bool = true) throws {
        directory = try TempDirectory()
        store = AppBoxConfigStore(directory: directory.url)
        if writesConfig {
            try store.save(config)
        }
        scanner = FakeAppScanner(records: records)
        icons = FakeIconProvider()
        launcher = FakeLauncher()
    }

    /// 配置文件不存在的 fixture——这就是「首次启动」。
    static func firstLaunch(records: [AppRecord] = []) throws -> ServiceFixture {
        try ServiceFixture(records: records, writesConfig: false)
    }

    var service: LibraryService {
        LibraryService(configStore: store, scanner: scanner, icons: icons, launcher: launcher)
    }
}
