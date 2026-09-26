import Foundation
import Testing

@testable import AppBoxCore

@Suite("引导建议：从类别推导分组")
struct SetupAdvisorTests {
    private let advisor = SetupAdvisor.standard

    @Test("没有类别的应用全部落进「未分类」，一条建议都不出")
    func unclassifiedApplicationsProduceNoSuggestion() {
        let plan = advisor.plan(from: [
            TestEntries.make("com.example.a", name: "A"),
            TestEntries.make("com.example.b", name: "B"),
        ])

        #expect(plan.suggestions.isEmpty)
        #expect(plan.unassigned.map(\.bundleIdentifier) == ["com.example.a", "com.example.b"])
        #expect(plan.unrecognizedCategories.isEmpty)
    }

    @Test("一个类别推出一条建议，名字是中文的分组名")
    func singleCategoryBecomesOneSuggestion() throws {
        let plan = advisor.plan(from: [
            TestEntries.make("com.example.terminal", name: "Terminal", category: "public.app-category.utilities"),
            TestEntries.make("com.example.disk", name: "Disk Utility", category: "public.app-category.utilities"),
        ])

        #expect(plan.suggestions.count == 1)
        let suggestion = try #require(plan.suggestions.first)
        #expect(suggestion.name == "工具")
        #expect(suggestion.applications.map(\.bundleIdentifier) == ["com.example.disk", "com.example.terminal"])
        #expect(plan.unassigned.isEmpty)
    }

    @Test("类别分散时按应用数量从多到少排，界面上一眼看出哪些组过大")
    func suggestionsAreOrderedBySizeDescending() {
        let utilities = (0..<5).map { TestEntries.make("com.example.u\($0)", name: "U\($0)", category: "public.app-category.utilities") }
        let developers = (0..<3).map { TestEntries.make("com.example.d\($0)", name: "D\($0)", category: "public.app-category.developer-tools") }
        let players = (0..<7).map { TestEntries.make("com.example.p\($0)", name: "P\($0)", category: "public.app-category.games") }

        let plan = advisor.plan(from: utilities + developers + players)

        #expect(plan.suggestions.map(\.name) == ["游戏", "工具", "开发工具"])
        #expect(plan.suggestions.map(\.applications.count) == [7, 5, 3])
    }

    @Test("只有一个应用的类别照样成一条建议：过滤规则会让用户看不懂少了什么")
    func singleApplicationCategoryStillAppears() {
        let plan = advisor.plan(from: [
            TestEntries.make("com.example.only", name: "Only", category: "public.app-category.music"),
            TestEntries.make("com.example.term", name: "Term", category: "public.app-category.utilities"),
        ])

        // 数量相同时按名字排，而名字的先后跟语言环境有关——这里只断言两条都在。
        #expect(plan.suggestions.count == 2)
        #expect(Set(plan.suggestions.map(\.name)) == ["音乐", "工具"])
        #expect(plan.suggestions.first { $0.name == "音乐" }?.applications.count == 1)
    }

    @Test("两个类别指向同一个分组名时并成一条")
    func categoriesSharingANameMerge() throws {
        let catalog = CategoryCatalog(table: [
            "alpha-tools": "工具",
            "beta-tools": "工具",
            "games": "游戏",
        ])
        let advisor = SetupAdvisor(catalog: catalog)

        let plan = advisor.plan(from: [
            TestEntries.make("com.example.a", name: "A", category: "public.app-category.alpha-tools"),
            TestEntries.make("com.example.b", name: "B", category: "public.app-category.beta-tools"),
            TestEntries.make("com.example.c", name: "C", category: "public.app-category.games"),
        ])

        #expect(plan.suggestions.map(\.name) == ["工具", "游戏"])
        let tools = try #require(plan.suggestions.first { $0.name == "工具" })
        #expect(tools.applications.map(\.bundleIdentifier) == ["com.example.a", "com.example.b"])
    }

    @Test("认不出的类别落进未分类，同时被记下来——不崩、不丢")
    func unrecognizedCategoriesFallBackToUnclassified() {
        let plan = advisor.plan(from: [
            TestEntries.make("com.example.new", name: "New", category: "public.app-category.something-new"),
            TestEntries.make("com.example.old", name: "Old", category: "public.app-category.utilities"),
        ])

        #expect(plan.suggestions.map(\.name) == ["工具"])
        #expect(plan.unassigned.map(\.bundleIdentifier) == ["com.example.new"])
        #expect(plan.unrecognizedCategories == ["public.app-category.something-new"])
    }

    @Test("同一个不认识的类别出现多次只记一条，按值排序")
    func unrecognizedCategoriesAreDeduplicated() {
        let plan = advisor.plan(from: [
            TestEntries.make("com.example.b1", name: "B1", category: "public.app-category.zeta"),
            TestEntries.make("com.example.a1", name: "A1", category: "public.app-category.alpha"),
            TestEntries.make("com.example.b2", name: "B2", category: "public.app-category.zeta"),
        ])

        #expect(plan.unrecognizedCategories == ["public.app-category.alpha", "public.app-category.zeta"])
        #expect(plan.unassigned.count == 3)
    }

    @Test("类别值带不带 public.app-category. 前缀都认")
    func prefixIsOptional() {
        let plan = advisor.plan(from: [
            TestEntries.make("com.example.a", name: "A", category: "utilities"),
            TestEntries.make("com.example.b", name: "B", category: "public.app-category.utilities"),
        ])

        #expect(plan.suggestions.count == 1)
        #expect(plan.suggestions.first?.applications.count == 2)
        #expect(plan.unrecognizedCategories.isEmpty)
    }

    @Test("空类别字符串与没有类别是一回事")
    func blankCategoryIsTreatedAsMissing() {
        let plan = advisor.plan(from: [
            TestEntries.make("com.example.a", name: "A", category: "   "),
            TestEntries.make("com.example.b", name: "B", category: nil),
        ])

        #expect(plan.suggestions.isEmpty)
        #expect(plan.unassigned.count == 2)
        #expect(plan.unrecognizedCategories.isEmpty)
    }

    @Test("一个应用都没有时是空计划")
    func emptyInputProducesEmptyPlan() {
        let plan = advisor.plan(from: [])

        #expect(plan.suggestions.isEmpty)
        #expect(plan.unassigned.isEmpty)
        #expect(plan.unrecognizedCategories.isEmpty)
    }

    @Test("建议里的成员按显示名排，与输入顺序无关")
    func membersAreOrderedByName() {
        let plan = advisor.plan(from: [
            TestEntries.make("com.example.z", name: "Zebra", category: "public.app-category.utilities"),
            TestEntries.make("com.example.a", name: "Ant", category: "public.app-category.utilities"),
            TestEntries.make("com.example.m", name: "Mole", category: "public.app-category.utilities"),
        ])

        #expect(plan.suggestions.first?.applications.map(\.realName) == ["Ant", "Mole", "Zebra"])
    }

    @Test("标准表认下 App Store 的常用类别")
    func standardCatalogCoversCommonCategories() {
        #expect(CategoryCatalog.standard.name(forCategory: "public.app-category.utilities") == "工具")
        #expect(CategoryCatalog.standard.name(forCategory: "public.app-category.developer-tools") == "开发工具")
        #expect(CategoryCatalog.standard.name(forCategory: "public.app-category.productivity") == "效率")
        #expect(CategoryCatalog.standard.name(forCategory: "public.app-category.games") == "游戏")
        // Chess.app 只声明 board-games：与 games 同归一组，靠「同名合并」走到一起。
        #expect(CategoryCatalog.standard.name(forCategory: "public.app-category.board-games") == "游戏")
        #expect(CategoryCatalog.standard.name(forCategory: nil) == nil)
        #expect(CategoryCatalog.standard.name(forCategory: "public.app-category.nope") == nil)
    }
}
