import Foundation

/// 搜索的匹配规则。纯函数，不持有状态。
///
/// 名字有两个"说法"：汉字按字面，拉丁字母按拼音。用哪个由输入的查询决定——
/// 打汉字就两边都按字面比，打字母才把两边都转成拼音形式。用同一种形式，
/// 前缀比较才有意义，「微信」「weixin」「wx」三条输入路径各有各的落点。
public enum AppSearch {
    /// 这条应用是否命中查询。匹配字段是真实名、别名、bundleID。
    public static func matches(query: String, entry: ApplicationEntry) -> Bool {
        guard !literalForm(query).isEmpty else { return false }

        if matchesName(query, entry.realName) { return true }
        if let alias = entry.alias, matchesName(query, alias) { return true }

        return matchesBundleIdentifier(query, entry.bundleIdentifier)
    }

    /// 命中查询的应用，跨分组平铺、隐藏的除外，按显示名排。
    public static func results(for query: String, in snapshot: LibrarySnapshot) -> [ApplicationEntry] {
        guard !literalForm(query).isEmpty else { return [] }
        return snapshot.visibleApplications
            .filter { matches(query: query, entry: $0) }
            .sorted { lhs, rhs in
                let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.bundleIdentifier < rhs.bundleIdentifier
            }
    }

    /// 一个名字字段是否命中。汉字查询按字面比，不改写：把「信」转成拼音 `xin`
    /// 反而会撞上「微信」里的音节，而它本意只是要找名字以「信」开头的应用。
    private static func matchesName(_ query: String, _ name: String) -> Bool {
        if query.contains(where: { !$0.isASCII }) {
            return matchesWords(literalForm(query), literalForm(name))
        }
        return matchesWords(normalized(query), normalized(name))
    }

    /// 两个同形式的词串怎么算命中：连写前缀、整词前缀、缩写 + 尾词前缀。
    ///
    /// - `weixin` / `visualstudiocode`：连写前缀（汉字拼音转出来的形式是空格分隔的音节）。
    /// - `studio` / `wechat`：任一整词的前缀——词中间不算，`dio` 匹配不上 `studio`。
    /// - `wx`（wei + xin）/ `vscode`（v·s + code）：前面若干词各取首字母，
    ///   最后一个词取前缀。前两种是它的特例，但单列出来更好读，也少走弯路。
    private static func matchesWords(_ needle: String, _ name: String) -> Bool {
        let words = name.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return false }

        let compact = compacted(needle)
        guard !compact.isEmpty else { return false }

        if words.joined().hasPrefix(compact) { return true }
        if words.contains(where: { $0.hasPrefix(needle) }) { return true }

        for lastWordIndex in 0..<words.count {
            var initials = ""
            for word in words[0..<lastWordIndex] { initials += String(word.prefix(1)) }
            guard compact.hasPrefix(initials) else { continue }
            if words[lastWordIndex].hasPrefix(String(compact.dropFirst(initials.count))) { return true }
        }
        return false
    }

    /// 标识符是机器名，没有"词"可言：命中「某一整段的前缀」就算——
    /// `tencent`、`com.tencent`、`xinwechat` 都落在这条规则里；单字母 `a`
    /// 不会因为出现在 `com.example` 中间就把所有应用捞出来。
    private static func matchesBundleIdentifier(_ query: String, _ identifier: String) -> Bool {
        // 查询里的点也拿掉：「com.tencent」与段串形式上的 `comtencent` 才是同一句话。
        let compact = normalized(query).filter { $0.isLetter || $0.isNumber }
        guard !compact.isEmpty else { return false }

        let segments = camelSeparated(identifier)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let joined = segments.joined()

        var start = joined.startIndex
        for segment in segments {
            if joined[start...].hasPrefix(compact) { return true }
            start = joined.index(start, offsetBy: segment.count)
        }
        return false
    }

    /// 字面形式：只小写、把空白压成一个空格，汉字原样留着。
    private static func literalForm(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// 统一形式：汉字转拼音、去声调、驼峰断词、小写、空白压成一个空格。
    private static func normalized(_ text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        let plain = latin.applyingTransform(.stripCombiningMarks, reverse: false) ?? latin
        return camelSeparated(plain)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func compacted(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    /// 在驼峰边界补一个空格：`VoiceMemos` → `Voice Memos`。
    /// 只在"小写/数字后跟大写"处断，`HTTP` 这种整段大写不动它。
    private static func camelSeparated(_ text: String) -> String {
        var result = ""
        var previous: Character?
        for character in text {
            if let previous, character.isUppercase, previous.isLowercase || previous.isNumber {
                result.append(" ")
            }
            result.append(character)
            previous = character
        }
        return result
    }
}
