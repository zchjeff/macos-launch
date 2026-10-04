import AppBoxCore
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 用 CoreImage 把二维码字节流画成 PNG。
///
/// 与 `SystemIconRenderer` 同一种分工：出图必须用系统图形框架，因此实现留在
/// `AppBox` 这一层，`AppBoxCore` 只持有协议与参数逻辑（容量校验、级别换算等）。
/// 好处是二维码的**规则**能脱离图形栈单测，而图形这一步只承担"把像素画对"。
///
/// 只依赖 CoreImage / ImageIO / UniformTypeIdentifiers，不碰 AppKit——
/// 因此不需要 UI 运行时，输出也天然是可写文件的字节流。
struct CoreImageQRCodeRenderer: QRCodeRendering {
    /// 输出图像的边长上限（像素）。
    ///
    /// 二维码最大是版本 40 的 177×177 模块。若照着界面上的缩放上限（64）放大，
    /// 一张图就是 11840×11840 像素——按 4 字节/像素算约 560 MB，够把进程直接干掉。
    /// 所以缩放要受像素预算约束：小码可以放得很大，大码则自动收敛到能用的尺寸。
    static let maximumPixelSize = 2048

    func render(payload: Data, options: QRCodeOptions) -> QRCodeBitmap? {
        let options = options.normalized
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(payload, forKey: "inputMessage")
        filter.setValue(options.correctionLevel.rawValue, forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        // `CIQRCodeGenerator` 的输出**自带 1 模块静区**：版本 1 得到 23×23 而不是 21×21。
        //
        // 这一点不查文档是看不出来的，而直接采用会让界面上的数字说谎——用户把静区设成 4，
        // 产物实际是 5。所以这里先把它扣掉，按「模块数 + 两侧静区」自建画布，
        // 再把系统输出**居中**画上去：自带的 1 模块会落进我们留出的静区里，
        // 静区设成 0 时则连它一起被画布裁掉。两种情形下界面数字都与产物一致。
        let systemSpan = Int(output.extent.width.rounded())
        let moduleSpan = systemSpan - 2
        guard moduleSpan > 0 else { return nil }

        let totalModules = moduleSpan + options.quietZone * 2
        // 缩放受**总模块数**约束，不能只信界面给的上限：
        // 一张版本 40 的码按上限放大就是上亿像素，够把进程直接干掉。
        let scale = max(1, min(options.scale, Self.maximumPixelSize / totalModules))

        // 标准样式走快路：直接用系统输出缩放居中，与增强前逐像素一致，不做逐模块重绘。
        if options.isPlainStyle {
            return renderPlain(output: output, scale: scale, totalModules: totalModules)
        }

        // 美化样式要先拿到「哪些模块是黑的」这张布尔矩阵，才能逐模块换形状、上色、叠 Logo。
        guard let matrix = sampleMatrix(from: output, systemSpan: systemSpan, moduleSpan: moduleSpan) else {
            // 采样失败（理论上不该发生）退化为标准样式，至少给用户一张能扫的码。
            return renderPlain(output: output, scale: scale, totalModules: totalModules)
        }
        return renderStyled(
            matrix: matrix,
            moduleSpan: moduleSpan,
            scale: scale,
            options: options
        )
    }

    // MARK: - 标准样式

    /// 黑白方块、无 Logo：沿用系统输出，只负责缩放、补静区、铺白底。
    private func renderPlain(output: CIImage, scale: Int, totalModules: Int) -> QRCodeBitmap? {
        let canvasSize = totalModules * scale
        let scaled = output.transformed(
            by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))
        )
        guard let symbol = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        let offset = (canvasSize - symbol.width) / 2

        // 画的是一张不透明的白底，而不是直接输出带 alpha 的图。
        // 两个理由：二维码四周的静区必须是白色（透明像素在有些扫码器眼里就是黑），
        // 而 CoreImage 的输出本身不保证留够静区，得由我们自己补。
        guard let canvas = makeCanvas(size: canvasSize) else { return nil }
        canvas.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
        // 放大是整数倍且原本就是黑白两色，插值只会把模块边界糊成灰边，反而更难扫。
        canvas.interpolationQuality = .none
        // 静区为 0 时 offset 为负，系统自带的静区就在这里被裁掉。
        canvas.draw(symbol, in: CGRect(x: offset, y: offset, width: symbol.width, height: symbol.height))

        return encode(canvas: canvas, size: canvasSize)
    }

    // MARK: - 美化样式

    /// 按模块矩阵逐格重绘：背景铺满，深色模块按形状与前景色绘制，最后叠 Logo。
    private func renderStyled(
        matrix: [[Bool]],
        moduleSpan: Int,
        scale: Int,
        options: QRCodeOptions
    ) -> QRCodeBitmap? {
        let style = options.style
        let totalModules = moduleSpan + options.quietZone * 2
        let canvasSize = totalModules * scale
        guard let canvas = makeCanvas(size: canvasSize) else { return nil }

        // 背景（含静区）整块铺满，之后只在深色模块上盖前景色。
        canvas.setFillColor(Self.cgColor(style.background))
        canvas.fill(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))

        canvas.setFillColor(Self.cgColor(style.foreground))
        let q = options.quietZone
        for r in 0..<moduleSpan {
            for c in 0..<moduleSpan where matrix[r][c] {
                // 矩阵 r=0 是顶行；CGContext 原点在左下，所以 y 从底部反推。
                let x = (q + c) * scale
                let y = (q + (moduleSpan - 1 - r)) * scale
                drawModule(in: canvas, rect: CGRect(x: x, y: y, width: scale, height: scale), shape: style.shape)
            }
        }

        if let logoData = style.logoData, let logo = Self.cgImage(from: logoData) {
            drawLogo(logo, in: canvas, style: style, canvasSize: canvasSize, moduleSize: scale)
        }

        return encode(canvas: canvas, size: canvasSize)
    }

    /// 画单个模块。圆角/圆点都留一点内缩，避免相邻模块粘连成一团糊。
    private func drawModule(in canvas: CGContext, rect: CGRect, shape: QRModuleShape) {
        switch shape {
        case .square:
            canvas.fill(rect)
        case .rounded:
            let radius = rect.width * 0.35
            canvas.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            canvas.fillPath()
        case .circle:
            // 圆点比方块细一点更精致；直径取 0.82 模块，四周留缝。
            let inset = rect.width * 0.09
            let dot = rect.insetBy(dx: inset, dy: inset)
            canvas.fillEllipse(in: dot)
        }
    }

    /// 中心叠 Logo：先垫一块背景色的圆角底板把底下的码点盖干净，再画 Logo。
    ///
    /// 垫底板是关键——不加的话 Logo 的半透明边缘会和码点混在一起，扫码器读不出定位。
    /// Logo 尺寸由 `logoScale` 决定（相对整码宽度），再放一圈内边距。
    private func drawLogo(
        _ logo: CGImage,
        in canvas: CGContext,
        style: QRCodeStyle,
        canvasSize: Int,
        moduleSize: Int
    ) {
        let side = Int((Double(canvasSize) * style.logoScale).rounded())
        guard side >= moduleSize * 3 else { return } // 太小就没必要垫底板了
        let origin = (canvasSize - side) / 2
        let box = CGRect(x: origin, y: origin, width: side, height: side)

        let pad = max(CGFloat(moduleSize), CGFloat(side) * 0.1)
        let plate = box.insetBy(dx: -pad, dy: -pad)
        let plateRadius = plate.width * 0.18
        canvas.setFillColor(Self.cgColor(style.background))
        canvas.addPath(CGPath(roundedRect: plate, cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil))
        canvas.fillPath()

        canvas.interpolationQuality = .high
        canvas.draw(logo, in: box)
    }

    // MARK: - 采样与工具

    /// 把系统输出（每模块 1 像素、含 1 模块自带静区）读成 moduleSpan×moduleSpan 的布尔矩阵。
    ///
    /// `true` 表示深色模块。先渲染进一个已知的 RGBA 上下文再逐字节取亮度，
    /// 不依赖 CoreImage 输出的具体像素格式。
    private func sampleMatrix(from output: CIImage, systemSpan: Int, moduleSpan: Int) -> [[Bool]]? {
        guard let small = CIContext().createCGImage(
            output,
            from: CGRect(x: 0, y: 0, width: systemSpan, height: systemSpan)
        ) else { return nil }

        guard let ctx = CGContext(
            data: nil,
            width: systemSpan,
            height: systemSpan,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(small, in: CGRect(x: 0, y: 0, width: systemSpan, height: systemSpan))
        guard let data = ctx.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: systemSpan * systemSpan * 4)
        let rowBytes = ctx.bytesPerRow

        // 扣掉系统自带的那 1 模块静区：源图 (systemSpan) 里外圈一圈是白边，取内层 moduleSpan。
        // 亮度用 R 通道即可——黑白输出 R=G=B。CGImage 第 0 行是顶行，与绘制约定一致。
        var matrix = [[Bool]](repeating: [Bool](repeating: false, count: moduleSpan), count: moduleSpan)
        for r in 0..<moduleSpan {
            let sy = r + 1
            for c in 0..<moduleSpan {
                let sx = c + 1
                let luminance = bytes[sy * rowBytes + sx * 4]
                matrix[r][c] = luminance < 128
            }
        }
        return matrix
    }

    /// 一张不透明的 RGBA 画布（`noneSkipLast`：RGB 有效、alpha 恒为 1，避免透明静区）。
    private func makeCanvas(size: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    }

    /// 画布 → PNG 字节 → 成品位图。
    private func encode(canvas: CGContext, size: Int) -> QRCodeBitmap? {
        guard let image = canvas.makeImage() else { return nil }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer, UTType.png.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return QRCodeBitmap(pngData: buffer as Data, pixelWidth: size, pixelHeight: size)
    }

    private static func cgColor(_ color: QRColor) -> CGColor {
        CGColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    /// 从图像字节（PNG/JPEG 皆可）解出首帧 CGImage。
    private static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
