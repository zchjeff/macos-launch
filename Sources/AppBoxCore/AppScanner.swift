import Foundation

/// 扫描标准目录，产出一份去重后的应用清单。
///
/// 只走文件系统与 `Info.plist`，不碰 AppKit——图标由 `IconRendering` 端口在外部补上。
public struct AppScanner: Sendable {
    public init() {}

    /// 扫描给定的根。真实机器上请用 `AppScanning` 的 `scan()`，
    /// 这个带参数的版本是给测试指向临时目录用的。
    public func scan(roots: [ScanRoot]) -> [AppRecord] {
        let candidates = roots.flatMap(candidates(in:))

        // 排序必须是全序，否则同一 bundleID 的胜者会随目录遍历顺序抖动，
        // 表现为图标与路径在两次扫描之间莫名切换。
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.directory.deduplicationRank != rhs.directory.deduplicationRank {
                return lhs.directory.deduplicationRank < rhs.directory.deduplicationRank
            }
            let lhsDepth = lhs.path.split(separator: "/").count
            let rhsDepth = rhs.path.split(separator: "/").count
            if lhsDepth != rhsDepth {
                return lhsDepth < rhsDepth
            }
            return lhs.path < rhs.path
        }

        var byIdentifier: [String: AppRecord] = [:]
        for candidate in ordered where byIdentifier[candidate.bundleIdentifier] == nil {
            byIdentifier[candidate.bundleIdentifier] = candidate
        }
        return byIdentifier.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// 一个扫描根下的所有应用包。
    ///
    /// 只看根目录本身与它的**一级子目录**（`/Applications/Utilities/Foo.app` 这类要收进来），
    /// 且从不进入 `.app` 内部，因此 `Foo.app/Contents/...` 里的 Helper 不会被当成应用。
    private func candidates(in root: ScanRoot) -> [AppRecord] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root.url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            // 目录不存在（比如没有 ~/Applications）不是错误，跳过即可。
            return []
        }

        var bundles: [URL] = []
        for entry in entries where isDirectory(entry) {
            if entry.pathExtension == "app" {
                bundles.append(entry)
            } else if let children = try? FileManager.default.contentsOfDirectory(
                at: entry,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                bundles.append(contentsOf: children.filter { isDirectory($0) && $0.pathExtension == "app" })
            }
        }

        return bundles.compactMap { record(forBundleAt: $0, in: root.directory) }
    }

    private func record(forBundleAt bundle: URL, in directory: ApplicationDirectory) -> AppRecord? {
        let info = infoPlist(in: bundle)
        let bundleIdentifier = (info?["CFBundleIdentifier"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? bundle.path

        return AppRecord(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName(from: info, bundle: bundle),
            path: bundle.path,
            category: info?["LSApplicationCategoryType"] as? String,
            directory: directory
        )
    }

    /// `Info.plist` 缺失或损坏时返回 nil——调用方按「没有元数据」处理，而不是丢掉这个应用。
    private func infoPlist(in bundle: URL) -> [String: Any]? {
        let url = bundle.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else {
            return nil
        }
        return plist as? [String: Any]
    }

    /// 显示名优先级：`CFBundleDisplayName`（用户可见名）> `CFBundleName` > 去掉 `.app` 的文件名。
    private func displayName(from info: [String: Any]?, bundle: URL) -> String {
        let keys = ["CFBundleDisplayName", "CFBundleName"]
        for key in keys {
            if let value = info?[key] as? String, !value.isEmpty {
                return value
            }
        }
        return bundle.deletingPathExtension().lastPathComponent
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
