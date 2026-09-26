import Foundation
import Testing

@testable import AppBoxCore

@Suite("搜索：匹配")
struct AppSearchMatchTests {
    private func app(_ id: String = "com.example.app", name: String, alias: String? = nil) -> ApplicationEntry {
        TestEntries.make(id, name: name, alias: alias)
    }

    @Test("中文名：精确与前缀都算，只出现在中间不算")
    func chineseNamesMatchByPrefix() {
        let wechat = app(name: "微信")
        #expect(AppSearch.matches(query: "微信", entry: wechat))
        #expect(AppSearch.matches(query: "微", entry: wechat))
        #expect(!AppSearch.matches(query: "信", entry: wechat))
    }

    @Test("拼音：首字母、全拼、直接输入中文都走同一条路", arguments: ["wx", "WX", "w", "weixin", "微信"])
    func pinyinFormsMatch(query: String) {
        #expect(AppSearch.matches(query: query, entry: app(name: "微信")))
    }

    @Test("词组的拼音首字母：计算器 → jsq")
    func pinyinInitialsForLongerNames() {
        #expect(AppSearch.matches(query: "jsq", entry: app(name: "计算器")))
        #expect(AppSearch.matches(query: "jisuanqi", entry: app(name: "计算器")))
        #expect(!AppSearch.matches(query: "jsr", entry: app(name: "计算器")))
    }

    @Test("英文名：大小写不敏感，整词前缀与缩写都算")
    func englishNamesAreCaseInsensitive() {
        let vscode = app(name: "Visual Studio Code")
        for query in ["vscode", "VSCode", "vsc", "vs", "visual", "studio", "code", "visualstudio"] {
            #expect(AppSearch.matches(query: query, entry: vscode), "「\(query)」该匹配 Visual Studio Code")
        }
        #expect(!AppSearch.matches(query: "dio", entry: vscode))
    }

    @Test("驼峰当作词边界：VoiceMemos 的 vm、WeChat 的 wc")
    func camelCaseSplitsWords() {
        #expect(AppSearch.matches(query: "vm", entry: app(name: "VoiceMemos")))
        #expect(AppSearch.matches(query: "wc", entry: app(name: "WeChat")))
    }

    @Test("别名与真实名都参与匹配")
    func aliasesMatchToo() {
        let entry = app(name: "WeChat", alias: "微信")
        #expect(AppSearch.matches(query: "wechat", entry: entry))
        #expect(AppSearch.matches(query: "wc", entry: entry))
        #expect(AppSearch.matches(query: "wx", entry: entry))
        #expect(AppSearch.matches(query: "微信", entry: entry))
    }

    @Test("bundleID 也参与：命中其中一段即可")
    func bundleIdentifierMatches() {
        let entry = app("com.tencent.xinWeChat", name: "微信")
        #expect(AppSearch.matches(query: "tencent", entry: entry))
        #expect(AppSearch.matches(query: "com.tencent", entry: entry))
        #expect(AppSearch.matches(query: "xinwechat", entry: entry))
    }

    @Test("无结果与空查询")
    func noMatchAndEmptyQuery() {
        let entry = app(name: "微信")
        #expect(!AppSearch.matches(query: "zzz", entry: entry))
        #expect(!AppSearch.matches(query: "", entry: entry))
        #expect(!AppSearch.matches(query: "   ", entry: entry))
    }
}

@Suite("搜索：结果清单")
struct AppSearchResultsTests {
    private func snapshot() -> LibrarySnapshot {
        LibrarySnapshot(groups: [
            GroupSnapshot(group: .ungrouped, applications: [
                TestEntries.make("com.example.apricot", name: "Apricot"),
                TestEntries.make("com.example.beta", name: "Beta"),
            ]),
            GroupSnapshot(group: Group(id: "dev", name: "开发工具"), applications: [
                TestEntries.make("com.example.apple", name: "Apple"),
                TestEntries.make("com.example.hidden", name: "AppHidden", isHidden: true),
            ]),
        ])
    }

    @Test("结果跨分组平铺，隐藏的不出现，按名称排")
    func flattenedAcrossGroups() {
        let results = AppSearch.results(for: "ap", in: snapshot())
        #expect(results.map(\.displayName) == ["Apple", "Apricot"])
    }

    @Test("空查询没有结果")
    func emptyQueryHasNoResults() {
        #expect(AppSearch.results(for: "", in: snapshot()).isEmpty)
        #expect(AppSearch.results(for: "   ", in: snapshot()).isEmpty)
    }

    @Test("没有命中就是空清单")
    func noMatchesMeansEmpty() {
        #expect(AppSearch.results(for: "zzz", in: snapshot()).isEmpty)
    }
}
