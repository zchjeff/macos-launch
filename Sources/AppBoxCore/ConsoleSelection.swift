import Foundation

/// 控制台左侧选中的东西：某个分组、「失效应用」那一栏，或者一个工具。
///
/// 用枚举而不是一个约定的字符串 id：失效列表不是分组，硬塞进分组列表就得靠
/// 「某个特殊的 id」来区分，那种东西迟早会被当成普通分组处理。
///
/// 单独一个文件而不是塞在 `ConsoleModel.swift` 里，是因为它被
/// `ConsoleSelectionValidity` 的规则直接引用，而那条规则要能脱离
/// `ConsoleModel`（及其 `@Observable` 宏）单独编译与测试。
public enum ConsoleSelection: Hashable, Sendable {
    case group(String)
    case missing
    /// 工具箱里的某个工具。工具没有 bundleID、不在配置里，因此只能是这样的一等公民。
    case tool(ToolIdentifier)
}
