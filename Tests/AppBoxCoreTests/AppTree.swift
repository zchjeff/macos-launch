import Foundation
import Testing

@testable import AppBoxCore

/// 在临时目录里搭一棵假的扫描根，喂给真实的 `FileManager` 实现。
/// 用真实文件系统而不是 mock：Info.plist 解析、目录遍历、嵌套规则这些正是最容易错的地方。
final class AppTree {
    /// 已规范化的根路径。`NSTemporaryDirectory()` 给的是 `/var/...`，
    /// 而 `FileManager` 遍历目录时返回 `/private/var/...`，不统一就没法直接比对路径。
    /// 用 `realpath(3)` 而不是 `resolvingSymlinksInPath()`——后者在这里不会把 `/var` 解开。
    private(set) var root: URL

    init() throws {
        let unresolved = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AppBoxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: try AppTree.canonicalPath(of: unresolved))
    }

    private static func canonicalPath(of url: URL) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else {
            throw CocoaError(.fileNoSuchFile)
        }
        return String(cString: buffer)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    enum InfoPlist {
        /// 写入这些键值。
        case valid([String: Any])
        /// 不创建 Info.plist（应用包里没有这个文件）。
        case missing
        /// 创建一个内容不是合法 plist 的 Info.plist。
        case corrupt
    }

    /// 造一个 `.app` 包，返回它的绝对路径。
    @discardableResult
    func app(_ relativePath: String, _ infoPlist: InfoPlist = .valid([:])) throws -> URL {
        try app(in: root, relativePath, infoPlist)
    }

    /// 在指定目录下造一个 `.app` 包。去重测试需要往多个扫描根里放同名应用。
    @discardableResult
    func app(in base: URL, _ relativePath: String, _ infoPlist: InfoPlist = .valid([:])) throws -> URL {
        let bundle = base.appendingPathComponent(relativePath, isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        let plistURL = contents.appendingPathComponent("Info.plist")
        switch infoPlist {
        case .valid(let entries):
            let data = try PropertyListSerialization.data(
                fromPropertyList: entries,
                format: .xml,
                options: 0
            )
            try data.write(to: plistURL)
        case .missing:
            break
        case .corrupt:
            try Data("这不是一个 plist".utf8).write(to: plistURL)
        }
        return bundle
    }

    /// 造一个扫描根，模拟 `/Applications`、`/System/Applications` 这类并列目录。
    func makeRoot(_ name: String, _ directory: ApplicationDirectory) throws -> ScanRoot {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return ScanRoot(url: url, directory: directory)
    }

    /// 造一个普通目录（不是应用包），用于测一级子目录。
    @discardableResult
    func directory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 造一个普通文件，用于验证非目录条目被忽略。
    @discardableResult
    func file(_ relativePath: String, contents: String = "") throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// 把这棵树当成 `/Applications` 扫描。
    var scanRoot: ScanRoot {
        ScanRoot(url: root, directory: .applications)
    }
}
