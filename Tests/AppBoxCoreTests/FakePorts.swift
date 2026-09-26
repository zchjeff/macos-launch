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

    init(records: [AppRecord] = [], config: AppBoxConfig = AppBoxConfig()) throws {
        directory = try TempDirectory()
        store = AppBoxConfigStore(directory: directory.url)
        try store.save(config)
        scanner = FakeAppScanner(records: records)
        icons = FakeIconProvider()
        launcher = FakeLauncher()
    }

    var service: LibraryService {
        LibraryService(configStore: store, scanner: scanner, icons: icons, launcher: launcher)
    }
}
