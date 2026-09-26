import AppBoxCore
import CoreServices
import Foundation

/// FSEvents 版目录监听。
///
/// 只关心「该重扫了」，不关心具体哪个文件变了，所以不要文件级事件：
/// 拖一个应用包进来会产生上百个文件级事件，而目录级的只有一条。
///
/// `latency` 是 FSEvents 自己的合并窗口，这段时间里的多次变更合成一次回调。
/// 取 0.5 秒是因为变更只来自「装 / 删 / 移动应用」这类低频操作，而重扫一次
/// 只要几十毫秒——用半秒延迟换掉一串连珠炮是划算的。加上 `LibrarySync`
/// 那一层同样大小的窗口，一个变更从落盘到界面刷新的上限约一秒。
final class FSEventsWatcher: Watching, @unchecked Sendable {
    private let paths: [String]
    private let latency: CFTimeInterval
    private let queue = DispatchQueue(label: "com.ethicall.appbox.fsevents")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var box: Unmanaged<CallbackBox>?

    /// - Parameter paths: 要监听的目录。**不存在也可以**：FSEvents 会在它
    ///   出现之后开始报事件（`~/Applications` 在不少机器上默认是没有的）。
    init(paths: [String], latency: CFTimeInterval = 0.5) {
        self.paths = paths
        self.latency = latency
    }

    deinit {
        stop()
    }

    func start(onChange: @escaping @Sendable () -> Void) {
        stop()

        let box = Unmanaged.passRetained(CallbackBox(onChange))
        var context = FSEventStreamContext(
            version: 0,
            info: box.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            box.release()
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            box.release()
            return
        }

        lock.withLock {
            self.stream = stream
            self.box = box
        }
    }

    func stop() {
        let (stream, box) = lock.withLock {
            defer {
                self.stream = nil
                self.box = nil
            }
            return (self.stream, self.box)
        }

        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        // 配对 `passRetained`。回调只持有未保留的指针，所以这一步必须在
        // Invalidate 之后——那时不会再有回调进来。
        box?.release()
    }
}

/// FSEvents 回调拿不到捕获上下文，只能揣一个裸指针，这里把它包回来。
private final class CallbackBox: @unchecked Sendable {
    let onChange: @Sendable () -> Void

    init(_ onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }
}
