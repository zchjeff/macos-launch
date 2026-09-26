import Foundation

/// 覆盖层要渲染的一条应用。
///
/// 与 `AppRecord` 的区别：名字已经是最终要显示的那个，`iconCachePath` 已经是可直接加载的
/// 文件路径，隐藏与锁定状态也一并带出来。UI 不需要再做任何解析、回退或查配置。
public struct ApplicationEntry: Sendable, Equatable, Identifiable {
    public let bundleIdentifier: String
    /// 真实名称。别名生效时界面仍要能说清「这究竟是哪个应用」。
    public let realName: String
    public let alias: String?
    public let path: String
    public let category: String?
    public let iconCachePath: String?
    public let isHidden: Bool
    public let isLocked: Bool

    public var id: String { bundleIdentifier }

    /// 最终显示名：有别名用别名，没有就用真实名称。
    public var displayName: String { alias ?? realName }

    public init(
        bundleIdentifier: String,
        realName: String,
        alias: String?,
        path: String,
        category: String?,
        iconCachePath: String?,
        isHidden: Bool,
        isLocked: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.realName = realName
        self.alias = alias
        self.path = path
        self.category = category
        self.iconCachePath = iconCachePath
        self.isHidden = isHidden
        self.isLocked = isLocked
    }
}

/// 「配置里有、磁盘上找不到」的一条记录。
///
/// 名称无从得知——扫描不到就没有真实名称，界面只能靠 bundleID、别名和最后见过的位置
/// 让用户认出它是谁。
public struct MissingApplication: Sendable, Equatable, Identifiable {
    public let bundleIdentifier: String
    public let alias: String?
    /// 最后一次见到它的位置。
    public let lastKnownPath: String?
    /// 它原本所属的分组，清理前供详情展示。
    public let groupID: String
    public let isHidden: Bool
    public let isLocked: Bool

    public var id: String { bundleIdentifier }

    public init(
        bundleIdentifier: String,
        alias: String?,
        lastKnownPath: String?,
        groupID: String,
        isHidden: Bool,
        isLocked: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.alias = alias
        self.lastKnownPath = lastKnownPath
        self.groupID = groupID
        self.isHidden = isHidden
        self.isLocked = isLocked
    }
}

/// 应用详情面板要显示的一条信息。
///
/// 存在的应用与失效的记录共用一套字段：失效的读不出真实名称与当前路径，
/// 那些字段就是 nil，面板照样把它说明白，不必为两种状态各写一套界面。
public struct ApplicationDetail: Sendable, Equatable, Identifiable {
    public let bundleIdentifier: String
    /// 扫描出来的真实名称；失效后无从得知。
    public let realName: String?
    public let alias: String?
    /// 存在时是当前路径，失效时是最后待过的位置。
    public let lastKnownPath: String?
    public let groupName: String?
    public let isHidden: Bool
    public let isLocked: Bool
    public let isMissing: Bool
    /// 图标缓存文件路径；失效的应用没有图标可显示。
    public let iconCachePath: String?

    public var id: String { bundleIdentifier }

    public init(
        bundleIdentifier: String,
        realName: String?,
        alias: String?,
        lastKnownPath: String?,
        groupName: String?,
        isHidden: Bool,
        isLocked: Bool,
        isMissing: Bool,
        iconCachePath: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.realName = realName
        self.alias = alias
        self.lastKnownPath = lastKnownPath
        self.groupName = groupName
        self.isHidden = isHidden
        self.isLocked = isLocked
        self.isMissing = isMissing
        self.iconCachePath = iconCachePath
    }
}

extension ApplicationDetail {
    public init(_ entry: ApplicationEntry, groupName: String?) {
        self.init(
            bundleIdentifier: entry.bundleIdentifier,
            realName: entry.realName,
            alias: entry.alias,
            lastKnownPath: entry.path,
            groupName: groupName,
            isHidden: entry.isHidden,
            isLocked: entry.isLocked,
            isMissing: false,
            iconCachePath: entry.iconCachePath
        )
    }

    public init(_ record: MissingApplication, groupName: String?) {
        self.init(
            bundleIdentifier: record.bundleIdentifier,
            realName: nil,
            alias: record.alias,
            lastKnownPath: record.lastKnownPath,
            groupName: groupName,
            isHidden: record.isHidden,
            isLocked: record.isLocked,
            isMissing: true
        )
    }
}

/// 一个分组连同它组内、已按排序权重排好的应用。
public struct GroupSnapshot: Sendable, Equatable, Identifiable {
    public let group: Group
    /// 组内全部应用，含被隐藏的那些——控制台要能看到并恢复它们。
    public let applications: [ApplicationEntry]

    public var id: String { group.id }

    /// 覆盖层能看到的那部分。隐藏的应用连分组方块的缩略图都不进。
    public var visibleApplications: [ApplicationEntry] {
        applications.filter { !$0.isHidden }
    }

    public init(group: Group, applications: [ApplicationEntry]) {
        self.group = group
        self.applications = applications
    }
}

/// 某一时刻渲染就绪的分组结构。
///
/// 空分组也会出现：空分组是保留的，用户还要往里放东西。
public struct LibrarySnapshot: Sendable, Equatable {
    /// 分组，顺序即展示顺序。
    public let groups: [GroupSnapshot]
    /// 配置里有、磁盘上找不到的应用，按 bundleID 排序。
    public let missing: [MissingApplication]

    public init(groups: [GroupSnapshot], missing: [MissingApplication] = []) {
        self.groups = groups
        self.missing = missing
    }

    /// 覆盖层的平铺清单：跨分组、隐藏的除外。
    ///
    /// 没有「全部应用」这种投影，是为了让每个调用方都必须明说自己要不要隐藏的那些——
    /// 「隐藏的应用不出现在覆盖层的任何位置」这条规则只有一处可违反，就好查。
    public var visibleApplications: [ApplicationEntry] {
        groups.flatMap(\.visibleApplications)
    }
}
