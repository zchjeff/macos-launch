import Foundation

/// 类别值到分组名的映射表。
///
/// 整张表就是分类知识的唯一出处：认一个新类别只需要加一行，不允许别处再长出
/// 「如果是工具类就……」这样的分支——那种写法每加一个类别都要改代码，
/// 而且第一个特例出现之后就会有第二个。
public struct CategoryCatalog: Sendable {
    /// 系统存的是 `public.app-category.utilities` 这种形状。历史上的应用也可能只写后半段，
    /// 两种都按同一个 key 查表。
    static let prefix = "public.app-category."

    /// App Store 的常用类别。表里没有的一律认不出来——认不出来不等于出错，
    /// 调用方会把那些应用留在「未分类」里（见 `SetupAdvisor`）。
    public static let standard = CategoryCatalog(table: [
        "board-games": "游戏",
        "books": "图书",
        "business": "商务",
        "developer-tools": "开发工具",
        "education": "教育",
        "entertainment": "娱乐",
        "finance": "财务",
        "food-and-drink": "餐饮",
        "games": "游戏",
        "graphics-design": "图形设计",
        "healthcare-fitness": "健康健身",
        "lifestyle": "生活",
        "magazines-and-newspapers": "报刊",
        "medical": "医疗",
        "music": "音乐",
        "news": "新闻",
        "photography": "摄影",
        "productivity": "效率",
        "reference": "参考",
        "shopping": "购物",
        "social-networking": "社交",
        "sports": "运动",
        "stickers": "贴纸",
        "travel": "旅行",
        "utilities": "工具",
        "video": "视频",
        "weather": "天气",
        "word-processing": "文字处理",
    ])

    private let table: [String: String]

    public init(table: [String: String]) {
        self.table = table
    }

    /// 查不出名字就给 nil。nil 与「空白类别」都当作没有类别。
    public func name(forCategory value: String?) -> String? {
        guard let value else { return nil }
        let key = Self.key(forCategory: value)
        return key.isEmpty ? nil : table[key]
    }

    /// 归一化：去掉首尾空白与统一前缀。认不认识是查表的事，这里只负责让两种写法对上同一个 key。
    static func key(forCategory value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix(prefix) ? String(trimmed.dropFirst(prefix.count)) : trimmed
    }
}

/// 向导给出的一条分组建议。
public struct SetupSuggestion: Identifiable, Sendable, Equatable {
    /// 列表里的身份：出生时的分组名。改名不改它——改了界面就认不出这是同一行。
    /// 出生时不可能重名（重名的在 `SetupAdvisor` 里已经并成一条了）。
    public let id: String
    public var name: String
    public var applications: [ApplicationEntry]

    init(name: String, applications: [ApplicationEntry]) {
        self.id = name
        self.name = name
        self.applications = applications
    }
}

/// 一次引导整理的全部建议。
public struct SetupPlan: Sendable, Equatable {
    public var suggestions: [SetupSuggestion]
    /// 没进任何建议的应用：没声明类别的，以及类别认不出来的。
    public var unassigned: [ApplicationEntry]
    /// 表里没有的类别值，去重后按值排序。界面拿它说明一句「这些先留在未分类」，
    /// 维护的人也能照着往表里补一行。
    public var unrecognizedCategories: [String]

    public init(
        suggestions: [SetupSuggestion] = [],
        unassigned: [ApplicationEntry] = [],
        unrecognizedCategories: [String] = []
    ) {
        self.suggestions = suggestions
        self.unassigned = unassigned
        self.unrecognizedCategories = unrecognizedCategories
    }
}

/// 从扫描结果推导分组建议。
///
/// 建议一定是粗糙的（类别只分到「工具」这一层，而且一个类别动辄几十个应用），
/// 所以这里不试图猜得更准：推出来的东西只管给用户一个能改的起点，
/// 改得动、删得掉、能合并，比猜得准重要。
public struct SetupAdvisor: Sendable {
    public static let standard = SetupAdvisor(catalog: .standard)

    private let catalog: CategoryCatalog

    public init(catalog: CategoryCatalog) {
        self.catalog = catalog
    }

    public func plan(from entries: [ApplicationEntry]) -> SetupPlan {
        // 按分组名归并，而不是按类别值：表里两个类别指向同一个名字时，
        // 它们本来就是同一组，界面不该出现两行同名的建议。
        var grouped: [String: [ApplicationEntry]] = [:]
        var unassigned: [ApplicationEntry] = []
        var unrecognized: Set<String> = []

        for entry in entries {
            let value = entry.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty, let name = catalog.name(forCategory: value) {
                grouped[name, default: []].append(entry)
            } else {
                unassigned.append(entry)
                if !value.isEmpty {
                    unrecognized.insert(value)
                }
            }
        }

        let suggestions = grouped
            .map { name, applications in
                SetupSuggestion(name: name, applications: applications.sorted(by: Self.precedes))
            }
            // 大的排前面：向导的界面要让人一眼看出哪些组过大，而不是假装分得很均匀。
            .sorted { left, right in
                if left.applications.count != right.applications.count {
                    return left.applications.count > right.applications.count
                }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }

        return SetupPlan(
            suggestions: suggestions,
            unassigned: unassigned.sorted(by: Self.precedes),
            unrecognizedCategories: unrecognized.sorted()
        )
    }

    /// 应用之间的先后。权重一律当 0，所以这条规则就是「按显示名排，同名用 bundleID 兜底」——
    /// 借 `Ordering` 是为了让全程序只有一套排序规则。
    static func precedes(_ lhs: ApplicationEntry, _ rhs: ApplicationEntry) -> Bool {
        Ordering.precedes(
            Ordering(identifier: lhs.bundleIdentifier, name: lhs.displayName, weight: 0),
            Ordering(identifier: rhs.bundleIdentifier, name: rhs.displayName, weight: 0)
        )
    }
}
