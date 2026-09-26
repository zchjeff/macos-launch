import Foundation

/// 覆盖层要渲染的一条应用。
///
/// 与 `AppRecord` 的区别：`displayName` 已经是最终要显示的名字（别名优先），
/// `iconCachePath` 已经是可直接加载的文件路径。UI 不需要再做任何解析或回退。
public struct ApplicationEntry: Sendable, Equatable, Identifiable {
    public let bundleIdentifier: String
    public let displayName: String
    public let path: String
    public let category: String?
    public let iconCachePath: String?

    public var id: String { bundleIdentifier }

    public init(
        bundleIdentifier: String,
        displayName: String,
        path: String,
        category: String?,
        iconCachePath: String?
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.path = path
        self.category = category
        self.iconCachePath = iconCachePath
    }
}

/// 一个分组连同它组内、已按排序权重排好的应用。
public struct GroupSnapshot: Sendable, Equatable, Identifiable {
    public let group: Group
    public let applications: [ApplicationEntry]

    public var id: String { group.id }

    public init(group: Group, applications: [ApplicationEntry]) {
        self.group = group
        self.applications = applications
    }
}

/// 某一时刻渲染就绪的分组结构。
///
/// 空分组也会出现：空分组是保留的，用户还要往里放东西。
public struct LibrarySnapshot: Sendable, Equatable {
    public let groups: [GroupSnapshot]

    public init(groups: [GroupSnapshot]) {
        self.groups = groups
    }

    /// 跨分组平铺的全部应用。搜索（009）要的就是这个形态，
    /// 覆盖层在分组方块（007）落地之前也用它渲染。
    public var allApplications: [ApplicationEntry] {
        groups.flatMap(\.applications)
    }
}
