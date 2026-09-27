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

    /// 组装当前应显示的分组结构。别名、隐藏、锁定、排序权重全部来自配置。
    ///
    /// - Parameter recordingPaths: 顺手把扫到的位置记进已跟踪的应用，作为日后「失效」的线索。
    ///   控制台开窗时用得上；覆盖层不用——覆盖层的唤起路径上一个字节都不该写盘（ticket 017）。
    public func snapshot(recordingPaths: Bool = false) -> LibrarySnapshot {
        let records = scanner.scan()
        if recordingPaths {
            rememberPaths(from: records)
        }
        let config = lock.withLock { self.config }

        let entries = records.map { record -> ApplicationEntry in
            let application = config.applications[record.bundleIdentifier]
            return ApplicationEntry(
                bundleIdentifier: record.bundleIdentifier,
                realName: record.displayName,
                alias: application?.alias,
                localizedName: record.localizedName,
                path: record.path,
                category: record.category,
                iconCachePath: icons.iconURL(for: record)?.path,
                isHidden: application?.hidden ?? false,
                isLocked: application?.locked ?? false
            )
        }

        let groups = config.groups.map { group in
            GroupSnapshot(
                group: group,
                applications: ordered(
                    entries.filter { config.group(for: $0.bundleIdentifier) == group.id },
                    in: config
                )
            )
        }

        let present = Set(records.map(\.bundleIdentifier))
        let missing = config.applications
            .compactMap { bundleIdentifier, application -> MissingApplication? in
                guard !present.contains(bundleIdentifier) else { return nil }
                return MissingApplication(
                    bundleIdentifier: bundleIdentifier,
                    alias: application.alias,
                    lastKnownPath: application.lastKnownPath,
                    groupID: application.groupID,
                    isHidden: application.hidden,
                    isLocked: application.locked
                )
            }
            .sorted { $0.bundleIdentifier < $1.bundleIdentifier }

        return LibrarySnapshot(groups: groups, missing: missing)
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
    /// 别名、隐藏、锁定、排序权重这些别的配置一个都不动。
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

    // MARK: - 单个应用

    /// 采纳一次引导整理：按计划建好分组、安置成员，**一次写盘**。
    ///
    /// 与逐个 `createGroup` + `move` 的差别不只是快慢：那样写会在中途留下半成品，
    /// 而这个方法的语义是「计划要么整份成立，要么什么都没发生」。名字先整批校验完
    /// 再进临界区，所以第二条名字不合法时，第一条也不会落盘。
    ///
    /// **空计划也会把配置写下去**：文件存在与否就是「首启过没过」的标志，
    /// 向导的「取消」走的就是这条路（取消 = 采纳一个空计划）。
    public func applySetup(_ groups: [GroupPlan]) throws {
        let plans = try groups.map { GroupPlan(name: try validated($0.name), members: $0.members) }

        try mutate(forcingWrite: true) { config in
            for plan in plans {
                let created = Group(id: UUID().uuidString, name: plan.name)
                config.groups.append(created)
                for member in plan.members {
                    var application = config.applications[member] ?? ApplicationConfig()
                    application.groupID = created.id
                    config.applications[member] = application
                }
            }
        }
    }

    /// 把应用移入某个分组。应用还没出现在配置里时会顺带建一条默认记录。
    public func move(bundleIdentifier: String, toGroup groupID: String) throws {
        try mutate { config in
            guard config.groups.contains(where: { $0.id == groupID }) else {
                throw GroupError.groupNotFound(groupID)
            }
            var application = config.applications[bundleIdentifier] ?? ApplicationConfig()
            // 锁定就是「这个应用待在这儿别动」，跨组也一样。
            guard !application.locked else {
                throw GroupError.applicationLocked(bundleIdentifier)
            }
            application.groupID = groupID
            config.applications[bundleIdentifier] = application
        }
    }

    /// 按给定顺序重排组内应用：数组下标即新的排序权重。
    ///
    /// 顺序由调用方给出，而不是服务自己按权重和名字重算：界面上的先后还取决于别名，
    /// 服务自己算出来的序会和用户看到的那一列对不上。
    ///
    /// 权重从 1 开始编（不是 0）。0 是「还没有排序记录」的默认权重，留出这一档垫底，
    /// 新装的应用才不会插到手排过的队列中间（见 `Ordering.precedes`）。
    ///
    /// 锁定的成员原位不动：它占的槽位先留出来，其余槽位按调用方给的顺序填。
    public func reorder(groupID: String, to bundleIdentifiers: [String]) throws {
        // 当前顺序要扫描才能算出来（先后取决于显示名），所以先算好再进临界区：
        // mutate 里那把锁不是递归的，在里面调 displayOrder 会死锁。
        let current = displayOrder(ofGroup: groupID)

        try mutate { config in
            guard config.groups.contains(where: { $0.id == groupID }) else {
                throw GroupError.groupNotFound(groupID)
            }
            let locked = Set(current.filter { config.applications[$0]?.locked == true })

            var reordered = current
            var incoming = bundleIdentifiers.filter { !locked.contains($0) }.makeIterator()
            for (position, member) in current.enumerated() where !locked.contains(member) {
                reordered[position] = incoming.next() ?? member
            }

            number(reordered, in: groupID, of: &config)
        }
    }

    /// 设置别名。nil 或全空白等同于清除——界面上「清空输入框」和「点清除」是同一件事。
    public func setAlias(_ alias: String?, for bundleIdentifier: String) throws {
        try update(bundleIdentifier) { application in
            let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
            application.alias = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
    }

    /// 隐藏或恢复。隐藏只影响覆盖层，应用本身与配置文件里的其它设置都不动。
    public func setHidden(_ hidden: Bool, for bundleIdentifier: String) throws {
        try update(bundleIdentifier) { $0.hidden = hidden }
    }

    /// 锁定或解锁组内位置。
    ///
    /// 锁定时要把当前位置固化成明确的编号：整组权重如果都是 0，下次排序（按名字）
    /// 就会把它挤回字母序里，锁定就成了摆设。编号要先算出来——理由同 `reorder`。
    public func setLocked(_ locked: Bool, for bundleIdentifier: String) throws {
        let groupID = currentConfig.group(for: bundleIdentifier)
        let order = locked ? displayOrder(ofGroup: groupID) : []

        try mutate { config in
            var application = config.applications[bundleIdentifier] ?? ApplicationConfig()
            application.locked = locked
            config.applications[bundleIdentifier] = application

            guard locked else { return }
            // 整组重新编号，锁定的那个连同邻居都拿到明确位置：
            // 它停在哪一格就一直停在哪一格，后来者只能排在末尾。
            number(order, in: groupID, of: &config)
        }
    }

    /// 清理一条失效记录：把这个应用的配置整条删掉，别名、分组、隐藏一并消失。
    ///
    /// 只动配置，不碰磁盘上的任何文件——「清理」是让 AppBox 忘掉它，
    /// 不是替用户删除什么。
    public func forget(bundleIdentifier: String) throws {
        try mutate { $0.applications.removeValue(forKey: bundleIdentifier) }
    }

    // MARK: - 内部

    /// 先落盘、成功了再认这次改动，避免内存与磁盘各说各话。
    ///
    /// 归一化之后跟当前一致就什么都不做：读路径（`snapshot(recordingPaths:)`）也会走这里，
    /// 没变化却写一次盘，等于每次开控制台都空改一次用户文件。
    ///
    /// - Parameter forcingWrite: 内容没变也照写。只有「向导结束」用得上——
    ///   它要的不是内容变化，而是让配置文件**存在**。
    private func mutate(forcingWrite: Bool = false, _ body: (inout AppBoxConfig) throws -> Void) throws {
        try lock.withLock {
            var draft = config
            try body(&draft)
            let normalized = draft.normalized()
            guard forcingWrite || normalized != config else { return }
            try configStore.save(normalized)
            config = normalized
        }
    }

    /// 改单个应用的配置，没有记录就顺带建一条。
    private func update(_ bundleIdentifier: String, _ change: (inout ApplicationConfig) -> Void) throws {
        try mutate { config in
            var application = config.applications[bundleIdentifier] ?? ApplicationConfig()
            change(&application)
            config.applications[bundleIdentifier] = application
        }
    }

    /// 按给定顺序给一组应用编号（从 1 起），顺带把归属写实。
    ///
    /// 没记录的应用要就地补一条：不补的话「编号」只写在空气里——
    /// 用户看到的顺序变了，配置里却什么都没有，下次重排又从头算。
    private func number(_ order: [String], in groupID: String, of config: inout AppBoxConfig) {
        for (position, member) in order.enumerated() {
            var application = config.applications[member] ?? ApplicationConfig()
            application.groupID = groupID
            application.orderWeight = position + 1
            config.applications[member] = application
        }
    }

    private func validated(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GroupError.emptyName }
        return trimmed
    }

    /// 把这次扫到的位置记进**已经在配置里的**应用。
    ///
    /// 不给扫到的每个应用都建记录：那等于把上百个用户从没碰过的应用写进配置文件，
    /// 还会让「失效」列表认领一堆跟他无关的条目。
    ///
    /// 失败就算了：这是读路径上顺手记的线索，写不进去最多是失效列表少了路径，
    /// 不值得让一次快照查询因此失败。
    private func rememberPaths(from records: [AppRecord]) {
        try? mutate { config in
            for record in records {
                guard var application = config.applications[record.bundleIdentifier],
                      application.lastKnownPath != record.path else { continue }
                application.lastKnownPath = record.path
                config.applications[record.bundleIdentifier] = application
            }
        }
    }

    /// 某个分组当前在界面上的先后。锁定时要把这个顺序固化下来，所以单独取一次。
    ///
    /// 扫不到的应用（已失效）不在其中：它在界面上没有位置可言，权重保持原样。
    private func displayOrder(ofGroup groupID: String) -> [String] {
        let config = lock.withLock { self.config }
        return scanner.scan()
            .filter { config.group(for: $0.bundleIdentifier) == groupID }
            .map { record in
                Ordering(
                    identifier: record.bundleIdentifier,
                    // 别名优先：用户看到的先后就是按他看到的那个名字排的。
                    name: config.applications[record.bundleIdentifier]?.alias ?? record.displayName,
                    weight: config.applications[record.bundleIdentifier]?.orderWeight ?? 0
                )
            }
            .sorted(by: Ordering.precedes)
            .map(\.identifier)
    }

    private func ordered(_ entries: [ApplicationEntry], in config: AppBoxConfig) -> [ApplicationEntry] {
        entries.sorted { left, right in
            Ordering.precedes(ordering(of: left, in: config), ordering(of: right, in: config))
        }
    }

    private func ordering(of entry: ApplicationEntry, in config: AppBoxConfig) -> Ordering {
        Ordering(
            identifier: entry.bundleIdentifier,
            name: entry.displayName,
            weight: config.applications[entry.bundleIdentifier]?.orderWeight ?? 0
        )
    }
}

/// 排序用的最小信息：顺序只取决于这几个字段，不必带上图标、路径这些重东西。
struct Ordering: Equatable {
    let identifier: String
    let name: String
    let weight: Int

    /// 组内先后的唯一规则：编号小的在前，**没编号的垫底**，同编号按显示名，最后用 bundleID 兜底。
    ///
    /// 没编号的垫底而不是打头：用户手排过的分组里，新装的应用该排在末尾，
    /// 而不是插进他排好的队列中间去——打头也只是插队的另一种形式。
    /// 兜底比较是为了让这个序成为全序，否则同名的两个应用先后会随输入顺序抖动。
    static func precedes(_ lhs: Ordering, _ rhs: Ordering) -> Bool {
        if (lhs.weight == 0) != (rhs.weight == 0) { return rhs.weight == 0 }
        if lhs.weight != rhs.weight { return lhs.weight < rhs.weight }

        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.identifier < rhs.identifier
    }
}

extension AppBoxConfig {
    /// 应用所属分组的 id。配置里没有记录的一律算「未分类」。
    func group(for bundleIdentifier: String) -> String {
        applications[bundleIdentifier]?.groupID ?? Group.ungroupedID
    }
}
