import Foundation

/// 二维码里的一个颜色，用 RGBA 分量表示（各分量 0...1）。
///
/// 刻意不用 `CGColor` / `NSColor`：本模块（`AppBoxCore`）不依赖系统框架，
/// 颜色在这里只是**参数**——真正的着色发生在渲染层（`CoreImageQRCodeRenderer`），
/// 那里才碰得到图形栈。纯分量存储让样式可以被等值比较、参与指纹、脱离图形栈单测。
public struct QRColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
    }

    public static let black = QRColor(red: 0, green: 0, blue: 0)
    public static let white = QRColor(red: 1, green: 1, blue: 1)

    /// 从 0...0xFFFFFF 的整数构造（界面里的十六进制输入更方便粘贴）。
    /// 取低 24 位：RRGGBB。
    public init(rgb: Int) {
        let value = rgb & 0xFFFFFF
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// 折回 0...0xFFFFFF 的整数（RRGGBB，忽略 alpha），供界面显示十六进制。
    public var rgbValue: Int {
        let r = Int((red * 255).rounded())
        let g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        return (r << 16) | (g << 8) | b
    }

    /// 是否接近纯白。渲染层据此决定静区要不要单独铺白底。
    public var isCloseToWhite: Bool {
        red > 0.94 && green > 0.94 && blue > 0.94 && alpha > 0.94
    }
}

/// 单个模块（二维码里最小的方块）的形状。
///
/// 这是"美化"的核心旋钮之一：方块是标准样式，圆角/圆点更柔和。
/// 注意形状会牺牲一点可扫性——越圆润，模块边界越少，所以搭配高纠错级别更稳。
public enum QRModuleShape: String, CaseIterable, Hashable, Sendable {
    /// 标准方块，最耐扫。
    case square
    /// 圆角方块。
    case rounded
    /// 圆点。
    case circle

    public var displayName: String {
        switch self {
        case .square: "方块"
        case .rounded: "圆角"
        case .circle: "圆点"
        }
    }
}

/// 二维码的美化样式：前景/背景色、模块形状、中心 Logo。
///
/// 与 `QRCodeOptions` 分开放置的理由：`options` 里的纠错级别、缩放、静区影响的是
/// **编码与像素尺寸**（逻辑层要参与容量校验），而样式纯粹是**画法**——只有渲染层用得到。
/// 两者关注点不同，各自演进。
public struct QRCodeStyle: Hashable, Sendable {
    /// 模块（码点）颜色。
    public var foreground: QRColor
    /// 背景颜色。二维码规范要求静区留白，浅色背景最稳；深色可能扫不出来。
    public var background: QRColor
    public var shape: QRModuleShape

    /// 中心 Logo 的图像字节（PNG）。nil 表示不放 Logo。
    ///
    /// 存字节而不是 `NSImage`：本模块不依赖系统框架，且字节可参与 `Hashable`
    /// （Logo 换了要触发重算，走指纹那条路）。
    public var logoData: Data?
    /// Logo 相对二维码宽度的比例（0...1）。经验值 0.15...0.25；越大越吃掉码点，
    /// 需要更高的纠错级别兜底。渲染前会被收进安全范围。
    public var logoScale: Double

    public init(
        foreground: QRColor = .black,
        background: QRColor = .white,
        shape: QRModuleShape = .square,
        logoData: Data? = nil,
        logoScale: Double = 0.2
    ) {
        self.foreground = foreground
        self.background = background
        self.shape = shape
        self.logoData = logoData
        self.logoScale = logoScale
    }

    /// 系统默认样式：黑白方块、无 Logo。等价于旧版渲染结果。
    public static let `default` = QRCodeStyle()

    /// 是否维持纯标准样式（黑白方块、无 Logo）。
    ///
    /// 渲染层据此走快路：默认样式直接采用 CoreImage 的原始输出，不做逐模块重绘，
    /// 既省算力也保证与增强前完全一致。
    public var isPlain: Bool {
        shape == .square && foreground == .black && background == .white && logoData == nil
    }

    /// 收进安全范围：Logo 比例最大 0.3（再大会盖掉太多定位点以外的码点，直接扫不出）。
    public var normalized: QRCodeStyle {
        var copy = self
        copy.logoScale = min(max(logoScale, 0.05), 0.3)
        return copy
    }

    /// 参与指纹的"轻量"表示。
    ///
    /// Logo 只取"有无 + 字节数"而非全量哈希：换一张大小相近的图仍是极少见情形，
    /// 而把整段 PNG 塞进指纹字符串既不美观也拖慢比较。字节数已能覆盖绝大多数改动。
    public var fingerprintToken: String {
        let logo = logoData.map { "logo:\($0.count)" } ?? "nologo"
        return "\(shape.rawValue)|fg:\(foreground.rgbValue)|bg:\(background.rgbValue)|\(logo)|\((logoScale * 100).rounded())"
    }
}
