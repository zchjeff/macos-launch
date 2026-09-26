import Foundation

/// 把应用图标渲染成 PNG 数据。失败返回 nil。
///
/// 抽成端口是为了让 `AppBoxCore` 不依赖 AppKit——真实实现用 `NSWorkspace`，
/// 测试用假实现，从而把缓存命中/失效的逻辑单独测干净。
public protocol IconRendering: Sendable {
    func pngData(forApplicationAt path: String) -> Data?
}

/// 图标磁盘缓存。
///
/// 缓存文件按「主键 + 应用包修改时间」命名，因此应用被更新后旧文件自然失配、
/// 自动重新渲染，不需要额外的元数据文件。配置文件与图标物理分离（ADR-0005）。
public struct IconCache: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        // 目录先建好：这样"渲染失败不留残留文件"这类断言可以简单地列目录验证。
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 应用图标的缓存文件路径。
    ///
    /// 命中缓存直接返回；未命中则调用 `renderer` 渲染并写盘。
    /// 应用包已不存在、渲染失败或写盘失败时返回 nil，调用方退回占位图标。
    public func iconURL(for record: AppRecord, renderer: some IconRendering) -> URL? {
        guard let modificationDate = modificationDate(ofItemAt: record.path) else { return nil }

        let url = directory.appendingPathComponent(fileName(for: record, modifiedAt: modificationDate))
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        guard let data = renderer.pngData(forApplicationAt: record.path) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return url
    }

    private func fileName(for record: AppRecord, modifiedAt date: Date) -> String {
        let stamp = Int(date.timeIntervalSince1970)
        return "\(encoded(record.bundleIdentifier))-\(stamp).png"
    }

    /// 把主键编码成文件名安全的形式。
    ///
    /// 用百分号编码而不是把非法字符替换成下划线——替换会让不同主键（例如
    /// `/A/B.app` 与 `/A:B.app`）落到同一个文件名上，互相覆盖。
    private func encoded(_ key: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-.")
        return key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
    }

    private func modificationDate(ofItemAt path: String) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date
    }
}
