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
        let canvasSize = totalModules * scale

        let scaled = output.transformed(
            by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))
        )
        guard let symbol = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        let offset = (canvasSize - symbol.width) / 2

        // 画的是一张不透明的白底，而不是直接输出带 alpha 的图。
        // 两个理由：二维码四周的静区必须是白色（透明像素在有些扫码器眼里就是黑），
        // 而 CoreImage 的输出本身不保证留够静区，得由我们自己补。
        guard let canvas = CGContext(
            data: nil,
            width: canvasSize,
            height: canvasSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }
        canvas.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
        // 放大是整数倍且原本就是黑白两色，插值只会把模块边界糊成灰边，反而更难扫。
        canvas.interpolationQuality = .none
        // 静区为 0 时 offset 为负，系统自带的静区就在这里被裁掉。
        canvas.draw(symbol, in: CGRect(x: offset, y: offset, width: symbol.width, height: symbol.height))

        guard let image = canvas.makeImage() else { return nil }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer, UTType.png.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return QRCodeBitmap(pngData: buffer as Data, pixelWidth: canvasSize, pixelHeight: canvasSize)
    }
}
