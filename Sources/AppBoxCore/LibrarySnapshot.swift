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

/// 某一时刻渲染就绪的应用列表。
public struct LibrarySnapshot: Sendable, Equatable {
    public let applications: [ApplicationEntry]

    public init(applications: [ApplicationEntry]) {
        self.applications = applications
    }
}
