import AppBoxCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 禁用智能引号的文本编辑器

/// 替代 SwiftUI `TextEditor`，显式关闭 macOS 系统级的智能引号/破折号/文本替换，
/// 确保用户输入的 `"` 不会被转换为 `"` `"`。
struct RawTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView.scrollableTextView()
        textView.hasVerticalScroller = true
        textView.hasHorizontalScroller = false
        textView.autohidesScrollers = true
        textView.drawsBackground = false

        guard let tv = textView.documentView as? NSTextView else { return textView }
        tv.delegate = context.coordinator
        tv.font = font
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 5, height: 8)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        return textView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
        }
        tv.font = font
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }
    }
}

/// 工具工作区的外壳：按窗口宽度决定「输入 / 输出」是左右并排还是上下堆叠。
///
/// 用 `ViewThatFits` 而不是读宽度做判断：左右布局里两个编辑区都设了**最小可读宽度**，
/// 放不下时 `ViewThatFits` 会自动挑下一个候选。这样"多窄算窄"的阈值由内容的实际
/// 需求说话，不必在代码里钉一个和字体、边距都会脱节的魔数。
struct ToolWorkspaceFrame<Input: View, Output: View>: View {
    @ViewBuilder var input: () -> Input
    @ViewBuilder var output: () -> Output

    /// 并排时每一侧至少要有这么宽，否则 JSON 的长行会挤成一团。
    private static var minimumSideWidth: CGFloat { 260 }
    /// 堆叠时每一侧至少要有这么高，否则两栏都看不见内容。
    private static var minimumStackHeight: CGFloat { 140 }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                input()
                    .frame(minWidth: Self.minimumSideWidth, maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .topLeading)
                Divider()
                output()
                    .frame(minWidth: Self.minimumSideWidth, maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .topLeading)
            }

            VStack(spacing: 12) {
                input()
                    .frame(maxWidth: .infinity, minHeight: Self.minimumStackHeight, maxHeight: .infinity,
                           alignment: .topLeading)
                Divider()
                output()
                    .frame(maxWidth: .infinity, minHeight: Self.minimumStackHeight, maxHeight: .infinity,
                           alignment: .topLeading)
            }
        }
        .padding(12)
    }
}

/// 「输入 / 输出」两栏各自的标题条。
struct ToolPane<Accessory: View, Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                accessory()
            }
            content()
        }
    }
}

/// JSON 格式化 / 压缩的工作区。
struct JSONToolView: View {
    var model: ToolboxModel

    var body: some View {
        ToolWorkspaceFrame {
            ToolPane(title: "输入", systemImage: "square.and.pencil", accessory: { EmptyView() }) {
                RawTextEditor(text: jsonInput)
                    .scrollContentBackground(.hidden)
                    .background(.background.opacity(0.5), in: .rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 0.5)
                    }
            }
        } output: {
            ToolPane(title: "输出", systemImage: "text.alignleft", accessory: {
                HStack(spacing: 8) {
                    indentPicker
                    Toggle("压缩", isOn: compactBinding)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                    Button("用结果替换输入") { model.adoptJSONOutput() }
                        .controlSize(.small)
                        .disabled(model.json.output == nil)
                }
            }) {
                output
            }
        }
        .navigationTitle("JSON 格式化")
    }

    private var jsonInput: Binding<String> {
        Binding(
            get: { model.json.input },
            set: { model.setJSONInput($0) }
        )
    }

    private var compactBinding: Binding<Bool> {
        Binding(
            get: { model.json.isCompact },
            set: { model.setJSONCompact($0) }
        )
    }

    private var indentPicker: some View {
        Picker("缩进", selection: indentBinding) {
            Text("2 空格").tag(JSONTool.Indent.spaces(2))
            Text("4 空格").tag(JSONTool.Indent.spaces(4))
            Text("Tab").tag(JSONTool.Indent.tab)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(model.json.isCompact)
    }

    private var indentBinding: Binding<JSONTool.Indent> {
        Binding(
            get: { model.json.indent },
            set: { model.setJSONIndent($0) }
        )
    }

    @ViewBuilder
    private var output: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let failure = model.json.failure {
                // 错误信息带行列号，直接可照着定位。
                Label(failure.localizedDescription, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let text = model.json.output {
                ScrollView {
                    Text(text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(.background.opacity(0.5), in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                }
            } else if model.json.failure == nil {
                placeholder("格式化结果会出现在这里")
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// 二维码生成的工作区。
struct QRCodeToolView: View {
    var model: ToolboxModel

    var body: some View {
        ToolWorkspaceFrame {
            ToolPane(title: "内容", systemImage: "qrcode", accessory: { EmptyView() }) {
                VStack(alignment: .leading, spacing: 8) {
                    RawTextEditor(text: qrInput, font: .systemFont(ofSize: NSFont.systemFontSize))
                        .scrollContentBackground(.hidden)
                        .background(.background.opacity(0.5), in: .rect(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.separator, lineWidth: 0.5)
                        }
                    optionsBar
                    Divider()
                    styleBar
                }
            }
        } output: {
            ToolPane(title: "预览", systemImage: "photo", accessory: {
                if let bitmap = model.qrCode.bitmap {
                    Button("导出 PNG…") { export(bitmap) }
                        .controlSize(.small)
                }
            }) {
                preview
            }
        }
        .navigationTitle("二维码生成")
    }

    private var qrInput: Binding<String> {
        Binding(
            get: { model.qrCode.input },
            set: { model.setQRCodeInput($0) }
        )
    }

    private var optionsBar: some View {
        HStack(spacing: 10) {
            Picker("纠错", selection: levelBinding) {
                Text("L").tag(QRCodeOptions.CorrectionLevel.low)
                Text("M").tag(QRCodeOptions.CorrectionLevel.medium)
                Text("Q").tag(QRCodeOptions.CorrectionLevel.quartile)
                Text("H").tag(QRCodeOptions.CorrectionLevel.high)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Stepper(value: scaleBinding, in: 1...64) {
                Text("尺寸 \(model.qrCode.options.scale)×")
                    .font(.caption)
            }
            .controlSize(.small)
        }
    }

    /// 美化样式控制区：模块形状、前景/背景色、中心 Logo。
    ///
    /// 换形状或叠 Logo 会吃掉模块边界，扫码成功率下降——所以这些控件默认就是
    /// 最稳的标准样式（方块、黑白、无 Logo），用户主动改才生效。
    private var styleBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("形状", selection: shapeBinding) {
                    ForEach(QRModuleShape.allCases, id: \.self) { shape in
                        Text(shape.displayName).tag(shape)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                ColorPicker("码点", selection: foregroundBinding, supportsOpacity: false)
                    .labelsHidden()
                ColorPicker("背景", selection: backgroundBinding, supportsOpacity: false)
                    .labelsHidden()
            }

            HStack(spacing: 10) {
                Button {
                    pickLogo()
                } label: {
                    Label(model.qrCode.options.style.logoData == nil ? "Logo…" : "更换 Logo",
                          systemImage: "photo.badge.plus")
                }
                .controlSize(.small)

                if model.qrCode.options.style.logoData != nil {
                    Stepper(value: logoScaleBinding, in: 0.1...0.3, step: 0.01) {
                        Text("Logo \(Int((model.qrCode.options.style.logoScale * 100).rounded()))%")
                            .font(.caption)
                    }
                    .controlSize(.small)

                    Button("移除", action: removeLogo)
                        .controlSize(.small)
                        .buttonStyle(.link)
                } else {
                    Text("在二维码中心叠一张 Logo")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                // 只在偏离标准样式时才给「重置」，标准态下这个按钮没意义。
                if model.qrCode.options.style != .default {
                    Button("恢复默认样式", action: resetStyle)
                        .controlSize(.small)
                        .buttonStyle(.link)
                }
            }
        }
    }

    private var shapeBinding: Binding<QRModuleShape> {
        Binding(
            get: { model.qrCode.options.style.shape },
            set: { shape in
                var style = model.qrCode.options.style
                style.shape = shape
                model.setQRCodeStyle(style)
            }
        )
    }

    private var foregroundBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(model.qrCode.options.style.foreground)) },
            set: { color in
                var style = model.qrCode.options.style
                style.foreground = QRColor(color)
                model.setQRCodeStyle(style)
            }
        )
    }

    private var backgroundBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(model.qrCode.options.style.background)) },
            set: { color in
                var style = model.qrCode.options.style
                style.background = QRColor(color)
                model.setQRCodeStyle(style)
            }
        )
    }

    private var logoScaleBinding: Binding<Double> {
        Binding(
            get: { model.qrCode.options.style.logoScale },
            set: { scale in
                var style = model.qrCode.options.style
                style.logoScale = scale
                model.setQRCodeStyle(style)
            }
        )
    }

    /// 选一张本地图作为中心 Logo。读不成图像就静默忽略（不给错，用户重选即可）。
    private func pickLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        var style = model.qrCode.options.style
        style.logoData = data
        model.setQRCodeStyle(style)
    }

    private func removeLogo() {
        var style = model.qrCode.options.style
        style.logoData = nil
        model.setQRCodeStyle(style)
    }

    private func resetStyle() {
        model.setQRCodeStyle(.default)
    }

    private var levelBinding: Binding<QRCodeOptions.CorrectionLevel> {
        Binding(
            get: { model.qrCode.options.correctionLevel },
            set: { level in
                var options = model.qrCode.options
                options.correctionLevel = level
                model.setQRCodeOptions(options)
            }
        )
    }

    private var scaleBinding: Binding<Int> {
        Binding(
            get: { model.qrCode.options.scale },
            set: { scale in
                var options = model.qrCode.options
                options.scale = scale
                model.setQRCodeOptions(options)
            }
        )
    }

    @ViewBuilder
    private var preview: some View {
        VStack(spacing: 8) {
            if let message = model.qrCode.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let bitmap = model.qrCode.bitmap, let image = NSImage(data: bitmap.pngData) {
                // 放大预览时用 `.none` 插值，模块边界保持锐利——糊了反而看不清结构。
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8)
                    .background(.white, in: .rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 0.5)
                    }
                    // 尺寸信息放在图下面：用户调 scale 时能立刻看到实际像素。
                    .overlay(alignment: .bottom) {
                        Text("\(bitmap.pixelWidth) × \(bitmap.pixelHeight) 像素")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 2)
                    }
            } else if model.qrCode.errorMessage == nil {
                Text("输入内容后这里会显示二维码")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    /// 导出 PNG。
    ///
    /// 这是整个工具箱里**唯一**会写磁盘的动作，而且必须由用户点按钮触发——
    /// 工具本身不产生任何副作用，这条边界写在 ADR-0007 里。
    private func export(_ bitmap: QRCodeBitmap) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "qrcode.png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? bitmap.pngData.write(to: url, options: .atomic)
    }
}

/// 随机密码的工作区。
///
/// 左栏是参数（长度、字符集、排除易混淆），右栏是生成的密码。
/// 参数改动**不**自动重生成（否则拖动长度时每挪一格密码都在跳），要用户显式点「生成密码」。
/// 密码只存在于内存，不写盘、不入配置；与其余工具同一套「纯计算、无副作用」边界（ADR-0007）。
struct PasswordToolView: View {
    var model: ToolboxModel

    var body: some View {
        ToolWorkspaceFrame {
            ToolPane(title: "参数", systemImage: "slider.horizontal.3", accessory: { EmptyView() }) {
                VStack(alignment: .leading, spacing: 10) {
                    Stepper(value: lengthBinding, in: PasswordGenerator.minimumLength...PasswordGenerator.maximumLength) {
                        Text("长度 \(model.password.options.length)")
                            .font(.callout.monospacedDigit())
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("小写字母 a-z", isOn: lowercaseBinding).toggleStyle(.checkbox)
                        Toggle("大写字母 A-Z", isOn: uppercaseBinding).toggleStyle(.checkbox)
                        Toggle("数字 0-9", isOn: digitsBinding).toggleStyle(.checkbox)
                        Toggle("符号", isOn: symbolsBinding).toggleStyle(.checkbox)
                    }

                    Divider()

                    Toggle("排除易混淆字符（0 O 1 l I）", isOn: excludeAmbiguousBinding)
                        .toggleStyle(.checkbox)

                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
                        Button(model.password.password.isEmpty ? "生成密码" : "重新生成") {
                            model.generatePassword()
                        }
                        .keyboardShortcut(.defaultAction)
                        .glassActionButton(prominent: true)
                        .disabled(!model.password.canGenerate)

                        if !model.password.canGenerate {
                            Text("请至少选择一种字符集")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(4)
            }
        } output: {
            ToolPane(title: "密码", systemImage: "key.fill", accessory: {
                Button("复制") { copyPassword() }
                    .controlSize(.small)
                    .disabled(model.password.password.isEmpty)
            }) {
                output
            }
        }
        .navigationTitle("随机密码")
        // 首次进入给一个默认密码，免得右栏一片空白；切走再切回不覆盖已有密码。
        .onAppear { model.ensureInitialPassword() }
    }

    private var lengthBinding: Binding<Int> {
        Binding(
            get: { model.password.options.length },
            set: { model.setPasswordLength($0) }
        )
    }

    private var lowercaseBinding: Binding<Bool> {
        Binding(
            get: { model.password.options.includesLowercase },
            set: { model.setPasswordIncludesLowercase($0) }
        )
    }

    private var uppercaseBinding: Binding<Bool> {
        Binding(
            get: { model.password.options.includesUppercase },
            set: { model.setPasswordIncludesUppercase($0) }
        )
    }

    private var digitsBinding: Binding<Bool> {
        Binding(
            get: { model.password.options.includesDigits },
            set: { model.setPasswordIncludesDigits($0) }
        )
    }

    private var symbolsBinding: Binding<Bool> {
        Binding(
            get: { model.password.options.includesSymbols },
            set: { model.setPasswordIncludesSymbols($0) }
        )
    }

    private var excludeAmbiguousBinding: Binding<Bool> {
        Binding(
            get: { model.password.options.excludesAmbiguous },
            set: { model.setPasswordExcludesAmbiguous($0) }
        )
    }

    @ViewBuilder
    private var output: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = model.password.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.password.password.isEmpty {
                Text(model.password.password)
                    .font(.system(.title3, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.background.opacity(0.5), in: .rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 0.5)
                    }
            } else if model.password.errorMessage == nil {
                Text("点「生成密码」，随机密码会出现在这里")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    /// 复制到剪贴板。这是用户显式点击才发生的动作，不算工具自身的副作用；
    /// 密码本身从不落盘、不写配置。
    private func copyPassword() {
        guard !model.password.password.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.password.password, forType: .string)
    }
}

/// 还没实现的工具：明确说清楚，而不是给一个点了没反应的空白页。
struct UnimplementedToolView: View {
    let tool: ToolIdentifier

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "hammer")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("「\(tool.displayName)」还没实现")
                .foregroundStyle(.secondary)
            Text("这一栏的位置已经留好，实现之后直接出现在这里。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension ToolIdentifier {
    /// 侧栏与标题里显示的名字。
    var displayName: String {
        switch self {
        case .jsonFormatter: "JSON 格式化"
        case .qrCode: "二维码生成"
        case .base64: "Base64 编解码"
        case .urlCodec: "URL 编解码"
        case .hashDigest: "哈希摘要"
        case .timestamp: "时间戳转换"
        case .textDiff: "文本对比"
        case .regexTester: "正则测试"
        case .jsonEscape: "JSON 转义"
        case .uuidGenerator: "UUID 生成"
        case .passwordGenerator: "随机密码"
        case .placeholderText: "占位文本"
        }
    }

    var systemImage: String {
        switch self {
        case .jsonFormatter: "curlybraces"
        case .qrCode: "qrcode"
        case .base64: "arrow.left.arrow.right.square"
        case .urlCodec: "link"
        case .hashDigest: "number"
        case .timestamp: "clock"
        case .textDiff: "arrow.left.and.right.text.vertical"
        case .regexTester: "textformat.abc"
        case .jsonEscape: "text.quote"
        case .uuidGenerator: "barcode"
        case .passwordGenerator: "key"
        case .placeholderText: "text.alignleft"
        }
    }
}

// MARK: - QRColor 与系统颜色的桥接

/// `QRColor` 是 `AppBoxCore` 里的纯分量参数；只有在这一层（AppBox）才把它翻译成
/// 系统颜色。两个方向都在这里，界面无需自己拆分量。
extension NSColor {
    convenience init(_ color: QRColor) {
        self.init(
            red: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.alpha)
        )
    }
}

extension QRColor {
    /// 从 SwiftUI `Color` 构造。先落到 sRGB 再取分量：ColorPicker 给的颜色
    /// 可能在扩展色域里，不先转换空间 `redComponent` 会直接崩溃。
    /// 取不出分量（非 RGB 色）时退化为黑。
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB)
        guard let ns else { self = .black; return }
        self.init(
            red: Double(ns.redComponent),
            green: Double(ns.greenComponent),
            blue: Double(ns.blueComponent),
            alpha: Double(ns.alphaComponent)
        )
    }
}
