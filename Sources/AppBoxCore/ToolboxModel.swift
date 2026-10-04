import Foundation
import Observation

/// 工具箱的状态。
///
/// 与 `ConsoleModel` 平级而不是塞进去：后者管的是「应用与分组」，工具与它毫无关系，
/// 混在一起会让那 388 行继续膨胀，也会让「目录变更时落回未分类」那类规则误伤工具态。
///
/// ## 关于「无状态」
/// 工具不往磁盘写任何东西：不进配置文件、不进 `schemaVersion`、不参与方案导入导出。
/// 但**内存里的输入要留住**——切到别的工具再切回来、或者把控制台窗口关掉再打开，
/// 刚才粘进去的内容必须还在，只有退出进程才该忘。
///
/// 这就是为什么状态挂在这里，而不是视图的 `@State`：控制台右栏是「按选中项分支」
/// 渲染出来的，切一次选中项 SwiftUI 就可能重建那棵子树，`@State` 会随之蒸发。
@MainActor
@Observable
public final class ToolboxModel {
    /// 当前选中的工具。nil 表示没在用工具（用户在分组或失效列表那边）。
    public var selectedTool: ToolIdentifier?

    /// 各工具自己的工作区状态，按工具分开存。
    ///
    /// 存进字典而不是一个 `switch` 里现取：工具的输入要能跨「切走再切回」保留，
    /// 每次新建一个 workspace 就等于把用户粘的东西扔掉。
    public private(set) var json = JSONToolWorkspace()
    public private(set) var qrCode = QRCodeWorkspace()

    /// 正在跑的那次计算。切输入很快时，只认最后一次的结果——
    /// 否则先发起的慢计算回来晚了，会用旧结果盖掉新结果。
    private var computeTask: Task<Void, Never>?
    /// 当前正在算的输入指纹，用来丢弃过期结果。
    private var pendingFingerprint: String?

    private let qrRenderer: any QRCodeRendering

    public init(qrRenderer: any QRCodeRendering = .unavailable) {
        self.qrRenderer = qrRenderer
    }

    // MARK: - 选中项

    public func select(_ tool: ToolIdentifier?) {
        selectedTool = tool
        guard let tool else { return }
        recompute(tool)
    }

    // MARK: - JSON

    public func setJSONInput(_ text: String) {
        json.input = text
        recompute(.jsonFormatter, debounce: true)
    }

    public func setJSONIndent(_ indent: JSONTool.Indent) {
        json.indent = indent
        recompute(.jsonFormatter)
    }

    public func setJSONCompact(_ compact: Bool) {
        json.isCompact = compact
        recompute(.jsonFormatter)
    }

    /// 把输入换成格式化后的结果（「用格式化结果替换输入」）。
    public func adoptJSONOutput() {
        guard json.adoptOutput() else { return }
        recompute(.jsonFormatter)
    }

    // MARK: - 二维码

    public func setQRCodeInput(_ text: String) {
        qrCode.input = text
        recompute(.qrCode, debounce: true)
    }

    public func setQRCodeOptions(_ options: QRCodeOptions) {
        qrCode.options = options
        recompute(.qrCode)
    }

    /// 换用一套美化样式（颜色 / 形状 / Logo）。
    ///
    /// 与 `setQRCodeOptions` 分开只为让视图意图更直白：改的是样式而不是编码参数。
    /// 两者最终都落到 `qrCode.options` 上，同样触发立即重算（样式改动没有连续性，不必防抖）。
    public func setQRCodeStyle(_ style: QRCodeStyle) {
        var options = qrCode.options
        options.style = style
        setQRCodeOptions(options)
    }

    /// 重算某个工具。
    ///
    /// - Parameter debounce: 是否为「用户还在敲字」的连续输入。
    ///   连续输入要等一小会儿再算，否则每敲一个字符就重画一次二维码、
    ///   对整份 JSON 重排一遍，纯属浪费——而结果完全相同。
    ///   参数类改动（换缩进、换纠错级别）没有这种连续性，立即算。
    public func recompute(_ tool: ToolIdentifier, debounce: Bool = false) {
        computeTask?.cancel()

        // 先算指纹再起任务：慢计算回来时用它判断自己是不是过期了。
        let fingerprint = ToolboxFingerprint.make(
            tool,
            input: tool == .jsonFormatter ? json.input : qrCode.input,
            indent: json.indent,
            isCompact: json.isCompact,
            options: qrCode.options
        )
        pendingFingerprint = fingerprint

        // 用任务自己的副本去算，避免算的过程中用户又改了输入、
        // 读到一半新一半旧的混合状态。
        let jsonSnapshot = json
        let qrSnapshot = qrCode
        let renderer = qrRenderer

        computeTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(180))
                if Task.isCancelled { return }
            }

            var nextJSON = jsonSnapshot
            var nextQR = qrSnapshot
            switch tool {
            case .jsonFormatter:
                nextJSON.compute()
            case .qrCode:
                nextQR.compute(renderer: renderer)
            default:
                return
            }
            if Task.isCancelled { return }

            guard let self else { return }
            // 过期结果直接丢掉：用户的输入已经往前走了，拿旧结果填上去就是骗人。
            guard self.pendingFingerprint == fingerprint else { return }
            switch tool {
            case .jsonFormatter: self.json = nextJSON
            case .qrCode: self.qrCode = nextQR
            default: break
            }
        }
    }
}
