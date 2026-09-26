import Foundation

/// 一个方案的完整配置。
///
/// 现在还只有版本号：分组、别名、隐藏、全局设置分别由 006 / 011 / 013 逐片填进来。
public struct AppBoxConfig: Codable, Sendable, Equatable {
    public let schemaVersion: Int

    public init(schemaVersion: Int = AppBoxConfig.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
    }
}

extension AppBoxConfig {
    /// 当前代码写出的 schema 版本。
    ///
    /// `Codable` 遇到缺失或类型不符的字段会直接解码失败，字段增删改都可能让旧文件读不出来，
    /// 所以这个数字不是装饰：任何字段变更都要 +1，并在 `AppBoxConfigStore.migrate` 里补一段升级。
    public static let currentSchemaVersion = 1

    /// 默认方案名，也是首次启动时创建的那个方案。
    public static let defaultProfileName = "default"
}
