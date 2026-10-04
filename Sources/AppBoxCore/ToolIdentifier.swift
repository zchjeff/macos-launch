import Foundation

/// 工具箱里的工具。
///
/// 用 enum 而不是字符串 id：工具是**编译期已知的固定集合**，侧栏要穷尽它、
/// 选中项要能安全地与 `ConsoleSelection` 并存。字符串 id 会允许「侧栏里冒出一个
/// 对不上任何工具的空洞」，而 enum 让这种状态根本写不出来。
///
/// 全部 case 一次定义齐，是为了让「加一个工具」变成*实现一个 case*，
/// 而不是*改动侧栏与选中项的结构*。
public enum ToolIdentifier: String, CaseIterable, Hashable, Sendable, Identifiable {
    case jsonFormatter
    case qrCode
    case base64
    case urlCodec
    case hashDigest
    case timestamp
    case textDiff
    case regexTester
    case jsonEscape
    case uuidGenerator
    case passwordGenerator
    case placeholderText

    public var id: String { rawValue }

    /// 是否已经有实现。
    ///
    /// 侧栏把没实现的置灰、不让选：点了没反应比这一项不存在更糟，
    /// 也与「界面不说谎」这条既有规矩一致（对照登录项开关失败会弹回）。
    /// 每实现一个工具，就把它的分支从 `false` 挪走。
    public var isImplemented: Bool {
        switch self {
        case .jsonFormatter, .qrCode: true
        case .base64, .urlCodec, .hashDigest, .timestamp, .textDiff,
             .regexTester, .jsonEscape, .uuidGenerator, .passwordGenerator, .placeholderText:
            false
        }
    }
}
