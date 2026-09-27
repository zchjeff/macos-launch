import Foundation

/// 应用所在的标准目录。
///
/// 顺序即去重优先级：同一 bundleID 出现在多处时保留排在前面的那份。
public enum ApplicationDirectory: String, Sendable, CaseIterable {
    case applications = "/Applications"
    case systemApplications = "/System/Applications"
    case userApplications = "~/Applications"

    var deduplicationRank: Int {
        switch self {
        case .applications: 0
        case .systemApplications: 1
        case .userApplications: 2
        }
    }

    /// 真实机器上的扫描根。
    public static var defaultRoots: [ScanRoot] {
        allCases.map { directory in
            let path = (directory.rawValue as NSString).expandingTildeInPath
            return ScanRoot(url: URL(fileURLWithPath: path, isDirectory: true), directory: directory)
        }
    }
}

/// 一个扫描根：目录位置 + 它属于哪一类标准目录。
///
/// 拆成两个字段是为了让测试能指向临时目录，同时仍走真实的优先级逻辑。
public struct ScanRoot: Sendable, Equatable {
    public let url: URL
    public let directory: ApplicationDirectory

    public init(url: URL, directory: ApplicationDirectory) {
        self.url = url
        self.directory = directory
    }
}

/// 一个被扫描到的应用。
///
/// `bundleIdentifier` 是主键；应用没有可用的 `CFBundleIdentifier` 时退化成绝对路径，
/// 所以这个字段永远非空（ADR-0003）。
public struct AppRecord: Sendable, Equatable, Identifiable {
    public let bundleIdentifier: String
    public let displayName: String
    /// 中文本地化显示名（bundle 的 `zh*.lproj` 里写的那个）。
    /// 系统语言不是中文时 `displayName` 会是英文名，这条字段让拼音搜索仍然认得「微信」。
    public let localizedName: String?
    /// 最近已知路径。应用被移动或删除后这里会过时，由后续切片负责标记「失效」。
    public let path: String
    /// `LSApplicationCategoryType` 原样保留，分类建议在后续切片里解释它。
    public let category: String?
    public let directory: ApplicationDirectory
    /// 图标缓存文件路径；尚未渲染时为 nil。
    public var iconCachePath: String?

    public var id: String { bundleIdentifier }

    public init(
        bundleIdentifier: String,
        displayName: String,
        localizedName: String? = nil,
        path: String,
        category: String?,
        directory: ApplicationDirectory,
        iconCachePath: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.localizedName = localizedName
        self.path = path
        self.category = category
        self.directory = directory
        self.iconCachePath = iconCachePath
    }
}
