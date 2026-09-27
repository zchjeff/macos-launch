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

/// 目录变化的信号源。
///
/// 端口刻意保持「哑」：只把底层的帧变成一次回调，不做任何合并——
/// 合并放在 `LibrarySync` 里，那里能脱离 FSEvents 单独测。
public protocol Watching: AnyObject, Sendable {
    /// 开始监听。`onChange` 可能被密集调用，也可能来自任意线程。
    func start(onChange: @escaping @Sendable () -> Void)
    func stop()
}

/// 开机启动（登录项）的读写。
///
/// 状态的真源是系统（登录项列表），不是本应用的配置——用户可以在「系统设置」里
/// 把它关掉，界面必须跟着系统的说法走。实现放在 AppBox 一层（SMAppService），
/// 这里只留端口供控制台模型接线与测试替换。
public protocol LoginItemControlling: Sendable {
    /// 当前是否已注册为登录项。
    var status: Bool { get }
    /// 注册或取消注册；失败时抛错，由调用方决定怎么说。
    func setEnabled(_ enabled: Bool) throws
}

/// 没接端口时的占位：永远读不到、一开就报错。
///
/// 用于测试与「以不支持的方式运行」的场合——宁可响亮地失败，
/// 也不静默显示一个拨了没反应的开关。
public struct DisabledLoginItemController: LoginItemControlling {
    public init() {}

    public var status: Bool { false }

    public func setEnabled(_ enabled: Bool) throws {
        throw NSError(
            domain: "AppBox",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "当前运行方式不支持开机启动（需以 .app 形式运行）"]
        )
    }
}

extension LoginItemControlling where Self == DisabledLoginItemController {
    public static var disabled: Self { Self() }
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
