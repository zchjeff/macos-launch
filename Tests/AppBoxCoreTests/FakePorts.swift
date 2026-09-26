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
