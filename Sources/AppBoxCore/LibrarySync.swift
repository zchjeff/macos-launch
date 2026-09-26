import Foundation

/// 磁盘变更 → 快照的合流器。
///
/// 一次变更只做三件事，按这个顺序：重扫一遍、把新位置记进配置、把**同一份**
/// 快照分发给所有订阅者。分发同一份是有意的——覆盖层与控制台各自重扫就会
/// 各看到一份数据，中间隔着一个正在搬动的应用包时，两边显示的东西会不一致。
///
/// 节流也是必须的：往 `/Applications` 里拖 20 个应用会产生成百上千个事件，
/// 每个事件都重扫就是扫描风暴。窗口内的所有事件只换来一次重扫，而且窗口
/// **不因为新事件而延长**——事件再密集，刷新也只是往后推一个窗口，不会被
/// 无限推迟（那是防抖的毛病：持续写入时永远不刷）。
public final class LibrarySync: @unchecked Sendable {
    private let service: LibraryService
    private let watcher: any Watching
    private let window: Duration
    private let lock = NSLock()
    private var handlers: [@Sendable (LibrarySnapshot) -> Void] = []
    private var pending: Task<Void, Never>?
    /// 每次 `stop()` 递增，用来作废还在窗口里打盹的那次 settle。
    private var generation = 0

    /// - Parameter window: 合并窗口。FSEvents 自己还有一层 `latency`，
    ///   两者相加是这个变更从落盘到界面刷新的上限（见 `FSEventsWatcher`）。
    public init(service: LibraryService, watcher: any Watching, window: Duration = .milliseconds(500)) {
        self.service = service
        self.watcher = watcher
        self.window = window
    }

    /// 订阅变更后的快照。回调在后台跑，界面层自己切回主线程。
    public func subscribe(_ handler: @escaping @Sendable (LibrarySnapshot) -> Void) {
        lock.withLock { handlers.append(handler) }
    }

    /// 开始监听。启动时不主动发一次快照——首屏该由调用方自己决定什么时候算。
    public func start() {
        watcher.start { [weak self] in self?.schedule() }
    }

    public func stop() {
        watcher.stop()
        lock.withLock {
            generation += 1
            pending = nil
        }
    }

    /// 窗外的事件开一个新窗口，窗口内的事件直接吸收。
    private func schedule() {
        lock.lock()
        guard pending == nil else {
            lock.unlock()
            return
        }
        let generation = self.generation
        let window = self.window
        pending = Task { [weak self] in
            try? await Task.sleep(for: window)
            self?.settle(generation: generation)
        }
        lock.unlock()
    }

    /// 窗口到头：重扫一遍（顺带记下位置线索），把快照发给所有人。
    private func settle(generation: Int) {
        lock.lock()
        guard generation == self.generation else {
            lock.unlock()
            return
        }
        pending = nil
        let handlers = self.handlers
        lock.unlock()

        guard !handlers.isEmpty else { return }

        // 记录位置与发快照共用这一次扫描：`recordingPaths` 顺手把已跟踪应用的
        // 最新位置写进配置，「移动」和「删除」的区别全靠这条线索（ADR-0003）。
        let snapshot = service.snapshot(recordingPaths: true)
        for handler in handlers {
            handler(snapshot)
        }
    }
}
