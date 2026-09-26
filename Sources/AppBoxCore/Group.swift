import Foundation

/// 分组。归属制：一个应用在任一时刻只属于一个分组（ADR-0002）。
///
/// 分组在配置里的先后顺序就是数组顺序，不额外存一个 `order` 字段——
/// 存了就有两个真相来源，迟早对不上。
public struct Group: Codable, Sendable, Equatable, Identifiable {
    /// 「未分类」的固定 id。它不是普通分组：不可删除、不可重命名，
    /// 新发现的应用默认落在这里（CONTEXT.md）。
    public static let ungroupedID = "ungrouped"

    public static let ungrouped = Group(id: ungroupedID, name: "未分类")

    public let id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public var isUngrouped: Bool { id == Self.ungroupedID }
}

/// 单个应用的配置。没出现在配置里的应用一律按默认状态处理（未分类、不锁定）。
public struct ApplicationConfig: Codable, Sendable, Equatable {
    /// 所属分组的 id。归属制下这是唯一的分组信息。
    public var groupID: String
    /// 组内位置。相同权重之间按显示名排，所以默认 0 就是「按名字排」。
    public var orderWeight: Int

    public init(groupID: String = Group.ungroupedID, orderWeight: Int = 0) {
        self.groupID = groupID
        self.orderWeight = orderWeight
    }
}

/// 分组与归属的变更错误。
public enum GroupError: Error, Equatable {
    /// 「未分类」不可删除、不可重命名。
    case ungroupedIsProtected
    case groupNotFound(String)
    case emptyName
    /// 目标应用或目标分组不存在——多半是配置已经被别处改过了。
    case applicationNotFound(String)
}
