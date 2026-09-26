import Foundation

/// 一个方案的完整配置。
///
/// 单应用配置（别名、隐藏、失效状态）与全局设置分别由 011 / 013 逐片填进来。
public struct AppBoxConfig: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    /// 分组，数组顺序即展示顺序。「未分类」始终在其中（`normalized()` 保证）。
    public var groups: [Group]
    /// bundleID → 该应用的配置。没出现在这里的应用按默认状态处理。
    public var applications: [String: ApplicationConfig]

    public init(
        schemaVersion: Int = AppBoxConfig.currentSchemaVersion,
        groups: [Group] = [.ungrouped],
        applications: [String: ApplicationConfig] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.groups = groups
        self.applications = applications
    }

    /// 新增字段在这里给默认值，而不是靠迁移步骤去补——这样加字段不必抬版本号。
    /// 版本号只留给「旧文件读进新代码会读错」的变更，比如改字段含义、删字段、改类型。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        groups = try container.decodeIfPresent([Group].self, forKey: .groups) ?? [.ungrouped]
        applications = try container.decodeIfPresent([String: ApplicationConfig].self, forKey: .applications) ?? [:]
    }
}

extension AppBoxConfig {
    /// 当前代码写出的 schema 版本。
    ///
    /// `Codable` 遇到缺失或类型不符的字段会直接解码失败，字段增删改都可能让旧文件读不出来，
    /// 所以这个数字不是装饰：任何会让旧文件读错的变更都要 +1，并在 `AppBoxConfigStore` 里补迁移。
    public static let currentSchemaVersion = 2

    /// 默认方案名，也是首次启动时创建的那个方案。
    public static let defaultProfileName = "default"

    /// 补齐配置必须满足的形态：「未分类」一定存在，引用它的应用不会指向不存在的分组，
    /// 空白别名视同没有别名。
    ///
    /// 配置文件是可以手改的（ADR-0005），所以这层修复放在读入的边界上，
    /// 而不是假设磁盘上的内容一定合法。
    public func normalized() -> AppBoxConfig {
        var config = self

        if !config.groups.contains(where: \.isUngrouped) {
            config.groups.insert(.ungrouped, at: 0)
        }

        let knownIDs = Set(config.groups.map(\.id))
        for (bundleIdentifier, application) in config.applications {
            var repaired = application

            // 指向已消失分组的应用落回「未分类」，而不是从快照里消失。
            if !knownIDs.contains(repaired.groupID) {
                repaired.groupID = Group.ungroupedID
            }

            // 「有别名但全是空白」和「没有别名」是同一件事，落盘前统一成后者，
            // 免得界面上出现一个看不见字符的别名、却怎么点都清不掉。
            if let alias = repaired.alias {
                let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                repaired.alias = trimmed.isEmpty ? nil : trimmed
            }

            config.applications[bundleIdentifier] = repaired
        }

        return config
    }
}
