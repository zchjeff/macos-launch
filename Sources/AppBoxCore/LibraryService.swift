import Foundation

/// 领域逻辑的唯一门面：快照查询与全部变更操作都从这里走。
///
/// 是引用类型而不是结构体：配置是有状态的，而门面会被覆盖层与控制台同时持有，
/// 值语义会让两边各持一份副本、改了互相看不见。内部所有可变状态由一把锁守着。
public final class LibraryService: @unchecked Sendable {
    /// 构造时那次加载的结果。
    ///
    /// `.refusedUnsupportedSchema` 时服务以默认配置运行，磁盘上的文件一个字节都没动
    /// （`save` 会拒绝覆盖比自己新的配置）。上层应当据此提示用户。
    public let loadOutcome: ConfigLoadOutcome

    private let lock = NSLock()
    private var config: AppBoxConfig

    private let configStore: AppBoxConfigStore
    private let scanner: any AppScanning
    private let icons: any IconProviding
    private let launcher: any Launching

    public init(
        configStore: AppBoxConfigStore,
        scanner: any AppScanning,
        icons: any IconProviding,
        launcher: any Launching
    ) {
        self.configStore = configStore
        self.scanner = scanner
        self.icons = icons
        self.launcher = launcher

        // `load` 对默认方案名不会因为输入非法而抛错，读不出来会走 `.createdDefault`；
        // 真抛了说明磁盘有问题，此时除了用默认配置把应用拉起来也没有更好的选择。
        let outcome = (try? configStore.load()) ?? .createdDefault(AppBoxConfig())
        self.loadOutcome = outcome
        self.config = (outcome.usableConfig ?? AppBoxConfig()).normalized()
    }

    // MARK: - 查询

    /// 当前的配置。变更一律走下面的方法，不要试图改这个值。
    public var currentConfig: AppBoxConfig {
        lock.withLock { config }
    }

    /// 组装当前应显示的分组结构。
    ///
    /// - Parameters:
    ///   - aliases: bundleID → 别名。011 把别名挪进配置后，这个参数会去掉。
    ///   - hidden: 被隐藏的 bundleID，不进入快照。
    public func snapshot(aliases: [String: String] = [:], hidden: Set<String> = []) -> LibrarySnapshot {
        let config = lock.withLock { self.config }

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

        let weights = config.applications.mapValues(\.orderWeight)
        let groups = config.groups.map { group in
            let members = entries
                .filter { config.group(for: $0.bundleIdentifier) == group.id }
                .sorted { ordered($0, $1, weights: weights) }
            return GroupSnapshot(group: group, applications: members)
        }

        return LibrarySnapshot(groups: groups)
    }

    public func launch(_ entry: ApplicationEntry) {
        launcher.launch(bundleIdentifier: entry.bundleIdentifier, path: entry.path)
    }

    // MARK: - 分组变更

    public func createGroup(named name: String) throws -> Group {
        let trimmed = try validated(name)
        let group = Group(id: UUID().uuidString, name: trimmed)
        try mutate { $0.groups.append(group) }
        return group
    }

    public func renameGroup(id: String, to name: String) throws {
        let trimmed = try validated(name)
        try mutate { config in
            guard let index = config.groups.firstIndex(where: { $0.id == id }) else {
                throw GroupError.groupNotFound(id)
            }
            guard !config.groups[index].isUngrouped else {
                throw GroupError.ungroupedIsProtected
            }
            config.groups[index].name = trimmed
        }
    }

    /// 删除分组。组内应用全部落回「未分类」——只改归属，
    /// 别名、隐藏、排序权重这些别的配置一个都不动。
    public func deleteGroup(id: String) throws {
        try mutate { config in
            guard let index = config.groups.firstIndex(where: { $0.id == id }) else {
                throw GroupError.groupNotFound(id)
            }
            guard !config.groups[index].isUngrouped else {
                throw GroupError.ungroupedIsProtected
            }
            config.groups.remove(at: index)

            for bundleIdentifier in config.applications
                .filter({ $0.value.groupID == id })
                .map(\.key) {
                config.applications[bundleIdentifier]?.groupID = Group.ungroupedID
            }
        }
    }

    /// 把分组挪到指定位置。越界会被夹到两端，而不是报错——
    /// 调用方多半是拖拽落点算出来的下标，夹一下比让拖拽失败友好。
    public func moveGroup(id: String, toIndex index: Int) throws {
        try mutate { config in
            guard let current = config.groups.firstIndex(where: { $0.id == id }) else {
                throw GroupError.groupNotFound(id)
            }
            let group = config.groups.remove(at: current)
            config.groups.insert(group, at: min(max(index, 0), config.groups.count))
        }
    }

    /// 把应用移入某个分组。应用还没出现在配置里时会顺带建一条默认记录。
    public func move(bundleIdentifier: String, toGroup groupID: String) throws {
        try mutate { config in
            guard config.groups.contains(where: { $0.id == groupID }) else {
                throw GroupError.groupNotFound(groupID)
            }
            var application = config.applications[bundleIdentifier] ?? ApplicationConfig()
            application.groupID = groupID
            config.applications[bundleIdentifier] = application
        }
    }

    // MARK: - 内部

    /// 先落盘、成功了再认这次改动，避免内存与磁盘各说各话。
    private func mutate(_ body: (inout AppBoxConfig) throws -> Void) throws {
        try lock.withLock {
            var draft = config
            try body(&draft)
            let normalized = draft.normalized()
            try configStore.save(normalized)
            config = normalized
        }
    }

    private func validated(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GroupError.emptyName }
        return trimmed
    }

    private func resolvedName(for record: AppRecord, aliases: [String: String]) -> String {
        guard let alias = aliases[record.bundleIdentifier], !alias.isEmpty else {
            return record.displayName
        }
        return alias
    }

    /// 权重小的在前；权重相同时按显示名。最后用 bundleID 兜底，
    /// 让比较成为全序——否则同名的两个应用顺序会随输入顺序抖动。
    private func ordered(
        _ lhs: ApplicationEntry,
        _ rhs: ApplicationEntry,
        weights: [String: Int]
    ) -> Bool {
        let left = weights[lhs.bundleIdentifier] ?? 0
        let right = weights[rhs.bundleIdentifier] ?? 0
        if left != right { return left < right }

        let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.bundleIdentifier < rhs.bundleIdentifier
    }
}

extension AppBoxConfig {
    /// 应用所属分组的 id。配置里没有记录的一律算「未分类」。
    func group(for bundleIdentifier: String) -> String {
        applications[bundleIdentifier]?.groupID ?? Group.ungroupedID
    }
}
