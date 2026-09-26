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

/// 单个应用的配置。没出现在配置里的应用一律按默认状态处理（未分类、不隐藏、不锁定）。
public struct ApplicationConfig: Codable, Sendable, Equatable {
    /// 所属分组的 id。归属制下这是唯一的分组信息。
    public var groupID: String
    /// 组内位置。相同权重之间按显示名排，所以默认 0 就是「按名字排」。
    public var orderWeight: Int
    /// 显示名覆盖。nil 表示用真实名称。
    public var alias: String?
    /// 从覆盖层隐藏。应用本身不受影响，只是不再出现在覆盖层的任何位置。
    public var hidden: Bool
    /// 位置锁定。锁定时会把当前位置固化成明确的权重，此后不再被排序改动。
    public var locked: Bool
    /// 最近一次见到它的位置。应用被移走或删掉后，这是「失效」列表里唯一的线索。
    public var lastKnownPath: String?

    public init(
        groupID: String = Group.ungroupedID,
        orderWeight: Int = 0,
        alias: String? = nil,
        hidden: Bool = false,
        locked: Bool = false,
        lastKnownPath: String? = nil
    ) {
        self.groupID = groupID
        self.orderWeight = orderWeight
        self.alias = alias
        self.hidden = hidden
        self.locked = locked
        self.lastKnownPath = lastKnownPath
    }

    /// 与 `AppBoxConfig` 同样的规矩：新增字段在这里给默认值，不抬 schema 版本号。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groupID = try container.decodeIfPresent(String.self, forKey: .groupID) ?? Group.ungroupedID
        orderWeight = try container.decodeIfPresent(Int.self, forKey: .orderWeight) ?? 0
        alias = try container.decodeIfPresent(String.self, forKey: .alias)
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        locked = try container.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        lastKnownPath = try container.decodeIfPresent(String.self, forKey: .lastKnownPath)
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
    /// 应用位置已锁定，先解锁才能动它。
    case applicationLocked(String)
}

/// 错误要说给人听。
///
/// 界面上的每一次拒绝都得有个说法——「点了没反应」和「操作被拒绝」在用户眼里是同一件事，
/// 而前者看起来就是坏掉了。
extension GroupError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .ungroupedIsProtected:
            "「未分类」是系统保留分组，不能删除也不能重命名"
        case .groupNotFound(let id):
            "找不到分组「\(id)」，配置可能已被别处改动"
        case .emptyName:
            "分组名不能为空"
        case .applicationNotFound(let id):
            "找不到应用「\(id)」，配置可能已被别处改动"
        case .applicationLocked(let id):
            "「\(id)」的位置已锁定，先解锁再调整"
        }
    }
}
