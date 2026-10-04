import Foundation

/// 选中项的存续规则：一次快照更新之后，左边选中的东西还算不算数。
///
/// 单独抽出来，是因为这里有一条**写错了也很难发现**的规则：工具那一栏与磁盘无关，
/// 因此任何一次目录变更都不该把正在用工具的人踢回分组列表。
/// 留在 `ConsoleModel` 里的话，这条规则只能靠点界面碰运气验证——而它恰恰最该被盯住。
///
/// 入参刻意用 `Set<String>` 而不是 `LibrarySnapshot` / `[ApplicationEntry]`：
/// 函数只用到「有哪些 id」，收窄到它真正需要的东西，测试就不必先搭一整份快照才能问一句话。
public enum ConsoleSelectionValidity {
    /// 这个选中项在新快照里还存在吗。
    public static func isAvailable(
        _ selection: ConsoleSelection?,
        groupIDs: Set<String>,
        hasMissing: Bool
    ) -> Bool {
        switch selection {
        case .group(let id):
            groupIDs.contains(id)
        case .missing:
            hasMissing
        // 工具不依赖磁盘，永远有效。
        //
        // 没有这一条，`LibrarySync` 推来一次快照就会把正在用工具的人踢回分组列表：
        // 工具好好的，用户的输入却没了。
        case .tool:
            true
        case nil:
            false
        }
    }

    /// 某条应用记录在当前这一栏里还看得见吗。
    ///
    /// 看不见就该把详情面板收起来——换了分组、或者那条记录被清掉了，
    /// 原先选中的应用不该继续显示。
    public static func isListed(
        _ bundleIdentifier: String,
        selection: ConsoleSelection?,
        missingIdentifiers: Set<String>,
        visibleIdentifiers: Set<String>
    ) -> Bool {
        switch selection {
        case .missing:
            missingIdentifiers.contains(bundleIdentifier)
        case .group:
            visibleIdentifiers.contains(bundleIdentifier)
        // 工具那一栏里没有应用，因此任何选中的应用都不该继续显示。
        case .tool:
            false
        case nil:
            false
        }
    }
}
