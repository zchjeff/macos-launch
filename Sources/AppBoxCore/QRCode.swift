import Foundation

/// 二维码的生成参数。
public struct QRCodeOptions: Hashable, Sendable {
    /// 纠错级别。级别越高越耐污损，但能装的内容越少。
    public enum CorrectionLevel: String, CaseIterable, Hashable, Sendable {
        case low = "L"
        case medium = "M"
        case quartile = "Q"
        case high = "H"

        /// 字节模式下，版本 40 二维码在每个级别能装下的**最大字节数**。
        ///
        /// 这是 QR 规范的标准容量表。渲染器超了这个数只会给出失败或截断，
        /// 都不会是我们想要的结果——所以在 Core 侧先拦下来，报一句人话。
        public var byteCapacity: Int {
            switch self {
            case .low: 2953
            case .medium: 2331
            case .quartile: 1663
            case .high: 1273
            }
        }
    }

    /// 每个模块放大成多少像素。太小（<4）会把二维码压成扫不出来的马赛克。
    public var scale: Int
    /// 四周静区宽度，单位是模块。规范要求至少 4。
    public var quietZone: Int
    public var correctionLevel: CorrectionLevel

    public init(
        correctionLevel: CorrectionLevel = .medium,
        scale: Int = 10,
        quietZone: Int = 4
    ) {
        self.correctionLevel = correctionLevel
        self.scale = scale
        self.quietZone = quietZone
    }

    /// 收进合法范围。界面上的步进器可能给出 0 或负数，这里兜住。
    public var normalized: QRCodeOptions {
        var copy = self
        copy.scale = min(max(scale, 1), 64)
        copy.quietZone = min(max(quietZone, 0), 16)
        return copy
    }
}

/// 把文本变成二维码字节流时能出的问题。
public enum QRCodeError: Error, Equatable, Sendable {
    case emptyInput
    case tooLong(limit: Int, actual: Int)

    public var localizedDescription: String {
        switch self {
        case .emptyInput:
            "请先输入要编码的内容"
        case .tooLong(let limit, let actual):
            "内容太长：当前 (\(actual) 字节) 超出了所选纠错级别能装下的上限 (\(limit) 字节)。"
                + "可以缩短内容，或把纠错级别降到 L。"
        }
    }
}

/// 二维码的纯逻辑：把文本转成待编码的字节流，并在编码前校验。
///
/// 刻意与「画成位图」分开。位图那一步必须用 CoreImage，而本模块（`AppBoxCore`）
/// 是不依赖系统框架的；分开之后，容量校验、空输入、级别换算这些规则
/// 都能脱离图形栈单测（对照 `IconCache` 与 `IconRendering` 的关系）。
public enum QRCode {
    /// 把文本编成字节流。
    ///
    /// 输出的是 **UTF-8 字节**——不是 `String`。这一步是有意的：
    /// CoreImage 的 `CIQRCodeGenerator` 收的是 `Data`，按字节编码，
    /// 传 UTF-8 才能让中文与 emoji 正确落进码里。
    /// （已实测：非 ASCII 不会被替换成 `?`，`中` 与 `?` 生成的矩阵不同。）
    public static func payload(
        text: String,
        options: QRCodeOptions = QRCodeOptions()
    ) throws(QRCodeError) -> Data {
        guard !text.isEmpty else { throw QRCodeError.emptyInput }

        let data = Data(text.utf8)
        let capacity = options.correctionLevel.byteCapacity
        guard data.count <= capacity else {
            throw QRCodeError.tooLong(limit: capacity, actual: data.count)
        }
        return data
    }
}

/// 一张渲染好的二维码位图。
public struct QRCodeBitmap: Hashable, Sendable {
    /// PNG 字节，可直接写文件或喂给 `NSImage`。
    public let pngData: Data
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(pngData: Data, pixelWidth: Int, pixelHeight: Int) {
        self.pngData = pngData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// 把二维码字节流画成位图。
///
/// 端口存在的理由与 `IconProviding` 相同：出图必须用 CoreImage，
/// 而 `AppBoxCore` 不依赖系统框架。真实实现在 `AppBox` 一层注入，
/// 测试则给一个假实现——工具链的逻辑不必依赖图形栈才能验证。
///
/// 实现方负责安静区：CoreImage 的输出不带足够的留白，四边至少要留 4 个模块。
public protocol QRCodeRendering: Sendable {
    /// 渲染；超过系统能力时返回 nil，由调用方决定怎么说。
    func render(payload: Data, options: QRCodeOptions) -> QRCodeBitmap?
}

/// 没有接入渲染端口时的占位：永远渲染不出来。
///
/// 用于测试与「以不支持的方式运行」的场合——宁可明确地渲染失败，
/// 也不静默给出一张空白图。
public struct UnavailableQRCodeRenderer: QRCodeRendering {
    public init() {}

    public func render(payload: Data, options: QRCodeOptions) -> QRCodeBitmap? { nil }
}

extension QRCodeRendering where Self == UnavailableQRCodeRenderer {
    public static var unavailable: Self { Self() }
}
