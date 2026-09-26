import AppBoxCore
import AppKit

/// 用 `NSWorkspace` 提取真实应用图标。
struct SystemIconRenderer: IconRendering {
    /// 输出边长（像素）。
    ///
    /// `NSWorkspace` 给的图标是 1024×1024，直接存 PNG 约 1.5 MB 一个；
    /// 按本机 107 个应用算就是 160 MB 缓存，不可接受。覆盖层最大的方块在 2x 屏上
    /// 也就 200 像素出头，256 足够，单个文件降到几十 KB。
    static let pixelSize = 256

    func pngData(forApplicationAt path: String) -> Data? {
        let icon = NSWorkspace.shared.icon(forFile: path)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Self.pixelSize,
            pixelsHigh: Self.pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(
            in: NSRect(x: 0, y: 0, width: Self.pixelSize, height: Self.pixelSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }
}
