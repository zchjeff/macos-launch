import Foundation

/// 领域逻辑的唯一门面：快照查询与全部变更操作都从这里走。
///
/// 无状态——每次查询都向端口要最新数据。缓存与增量同步是后续切片的事，
/// 现在先保证「扫描 → 合并 → 渲染就绪」这条链路是单一、可测的。
public struct LibraryService: Sendable {
    private let scanner: any AppScanning
    private let icons: any IconProviding
    private let launcher: any Launching

    public init(scanner: any AppScanning, icons: any IconProviding, launcher: any Launching) {
        self.scanner = scanner
        self.icons = icons
        self.launcher = launcher
    }

    /// 组装当前应显示的应用列表。
    ///
    /// - Parameters:
    ///   - aliases: bundleID → 别名。005 接入持久化后由配置提供，现在由调用方传入。
    ///   - hidden: 被隐藏的 bundleID，不进入快照。
    public func snapshot(aliases: [String: String] = [:], hidden: Set<String> = []) -> LibrarySnapshot {
        let entries = scanner.scan()
            .filter { !hidden.contains($0.bundleIdentifier) }
            .map { record in
                ApplicationEntry(
                    bundleIdentifier: record.bundleIdentifier,
                    displayName: resolvedName(for: record, aliases: aliases),
                    path: record.path,
                    category: record.category,
                    iconCachePath: icons.iconURL(for: record)?.path
                )
            }
            // 排序用最终显示名，这样设了别名之后顺序也跟着别名走，不会看起来乱。
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        return LibrarySnapshot(applications: entries)
    }

    public func launch(_ entry: ApplicationEntry) {
        launcher.launch(bundleIdentifier: entry.bundleIdentifier, path: entry.path)
    }

    private func resolvedName(for record: AppRecord, aliases: [String: String]) -> String {
        guard let alias = aliases[record.bundleIdentifier], !alias.isEmpty else {
            return record.displayName
        }
        return alias
    }
}
