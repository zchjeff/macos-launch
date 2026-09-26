import Foundation

/// AppBox 的身份常量。
///
/// 集中在一处，让 Swift 代码与打包脚本引用同一份事实，避免 bundle ID 在
/// `Package.swift`、`Info.plist`、配置目录名之间各写一遍而漂移。
public enum AppBoxIdentity {
    public static let bundleIdentifier = "com.ethicall.appbox"
    public static let displayName = "AppBox"
    public static let version = "0.1.0"

    /// `~/Library/Application Support/AppBox`，配置与图标缓存的根目录。
    public static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(displayName, isDirectory: true)
    }

    /// 图标缓存目录。与配置文件物理分离，保证配置文件始终轻量（ADR-0005）。
    public static var iconsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("icons", isDirectory: true)
    }
}
