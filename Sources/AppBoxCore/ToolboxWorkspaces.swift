import Foundation

/// 用来判断一次计算是否已经过期的指纹。
///
/// 单独抽出来，是因为它承担着**最容易写错、又最难发现**的一条保证：
/// 用户连着敲字时会有多次计算在飞，先发起的慢计算可能后回来。
/// 少了这道判断，它会用旧输入的结果盖掉新结果——界面显示的文本与输入框对不上，
/// 而且看起来像是「工具算错了」。
///
/// 与 `ConsoleSelectionValidity` 同样的理由独立成类型：留在 `ToolboxModel`
/// （带 `@Observable` 宏）里的话，这条规则只能靠手点界面碰运气验证。
public enum ToolboxFingerprint {
    /// 只要会影响结果的输入或参数变了，指纹就变。
    public static func make(
        _ tool: ToolIdentifier,
        input: String,
        indent: JSONTool.Indent,
        isCompact: Bool,
        options: QRCodeOptions
    ) -> String {
        switch tool {
        case .jsonFormatter:
            "json|\(indent)|\(isCompact)|\(input.hashValue)"
        case .qrCode:
            // 不用 `\(options)` 的默认反射描述：那会把整段 Logo PNG 字节拼进字符串，
            // 既臃肿又拖慢比较。用 style 的轻量 token 单独承担美化参数的变化。
            "qr|\(options.correctionLevel)|\(options.scale)|\(options.quietZone)|\(options.style.fingerprintToken)|\(input.hashValue)"
        default:
            "\(tool.rawValue)|"
        }
    }
}

/// JSON 工具的界面状态。
///
/// 输入、参数、结果放在同一个值类型里，是为了让「改了什么 → 结果变成什么」
/// 能脱离视图与异步编排直接测。`ToolboxModel` 只负责把界面事件转成这里的方法调用。
public struct JSONToolWorkspace: Equatable, Sendable {
    public var input: String = ""
    public var indent: JSONTool.Indent = .spaces(2)
    /// 压成单行。与 `indent` 互斥——压缩时缩进不起作用。
    public var isCompact: Bool = false

    public private(set) var output: String?
    public private(set) var failure: JSONTool.Failure?

    public init() {}

    /// 输入是否为空（只有空白也算空）。
    ///
    /// 空输入不该报错：用户刚清空文本框就被红字骂一句，是纯粹的噪音。
    public var isEmpty: Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public mutating func compute() {
        guard !isEmpty else {
            output = nil
            failure = nil
            return
        }
        do {
            output = try JSONTool.reformat(input, indent: indent, compact: isCompact)
            failure = nil
        } catch {
            // 失败时必须清掉上一次的输出：留着旧结果会让用户以为「这次也格式化好了」。
            output = nil
            failure = error
        }
    }

    /// 用格式化后的结果替换输入。
    ///
    /// 没有输出时什么都不做：失败状态下按这个按钮不该把用户手写的文本换成空。
    /// 返回是否真的替换了，界面据此决定要不要给个提示。
    @discardableResult
    public mutating func adoptOutput() -> Bool {
        guard let output else { return false }
        input = output
        compute()
        return true
    }
}

/// 二维码工具的界面状态。
public struct QRCodeWorkspace: Equatable, Sendable {
    public var input: String = ""
    public var options: QRCodeOptions = QRCodeOptions()

    public private(set) var bitmap: QRCodeBitmap?
    public private(set) var errorMessage: String?

    public init() {}

    public var isEmpty: Bool {
        input.isEmpty
    }

    /// 算一次。
    ///
    /// 渲染器是**参数**而不是属性：出图要用 CoreImage，而本模块（`AppBoxCore`）
    /// 不依赖系统框架。传进来之后，测试就能用一个假渲染器把「容量校验先于渲染」
    /// 这类顺序约束测清楚，不必真的去画图。
    public mutating func compute(renderer: some QRCodeRendering) {
        guard !isEmpty else {
            bitmap = nil
            errorMessage = nil
            return
        }

        let payload: Data
        do {
            payload = try QRCode.payload(text: input, options: options)
        } catch {
            bitmap = nil
            errorMessage = error.localizedDescription
            return
        }

        guard let rendered = renderer.render(payload: payload, options: options) else {
            bitmap = nil
            errorMessage = "生成失败了：当前环境渲染不出二维码图像。"
            return
        }
        bitmap = rendered
        errorMessage = nil
    }
}
