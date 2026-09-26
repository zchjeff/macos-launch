import AppKit

/// 进程内图标缓存。
///
/// 磁盘缓存解决的是"不重复向系统要图标"，但 `NSImage` 每次构造都要重新读盘、
/// 真正解码发生在首次绘制时；而 SwiftUI 每次求值 `body` 都会重跑这段代码。
/// 覆盖层每次唤起都重建整棵视图树，控制台滚动时也在反复取同一批图标，
/// 缺了这层就会反复读同一批 PNG。
///
/// 覆盖层与控制台共用这一份：同一张 PNG 只解码一次。
@MainActor
enum IconImageStore {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(atPath path: String) -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}
