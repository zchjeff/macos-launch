import Foundation

/// 提供当前磁盘上的应用清单。
public protocol AppScanning: Sendable {
    func scan() -> [AppRecord]
}

extension AppScanner: AppScanning {
    public func scan() -> [AppRecord] {
        scan(roots: ApplicationDirectory.defaultRoots)
    }
}

/// 提供某个应用的图标文件路径；拿不到时返回 nil。
public protocol IconProviding: Sendable {
    func iconURL(for record: AppRecord) -> URL?
}

/// 启动应用。已在运行时由实现负责激活已有实例，而不是新开一个。
public protocol Launching: Sendable {
    func launch(bundleIdentifier: String, path: String)
}

/// 把「图标缓存」与「图标渲染」接成 `IconProviding`。
///
/// 两个组件分开是为了让缓存逻辑（命中/失效/写盘）不依赖 AppKit，可以单独测；
/// 这个适配器只负责把它们拼起来。
public struct CachedIcons: IconProviding {
    private let cache: IconCache
    private let renderer: any IconRendering

    public init(cache: IconCache, renderer: any IconRendering) {
        self.cache = cache
        self.renderer = renderer
    }

    public func iconURL(for record: AppRecord) -> URL? {
        cache.iconURL(for: record, renderer: renderer)
    }
}
