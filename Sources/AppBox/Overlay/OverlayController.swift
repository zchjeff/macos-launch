import AppBoxCore
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 覆盖层的生命周期与窗口配置。
///
/// 唤起瞬间判定目标屏幕、创建窗口、抢焦点；收起时把焦点还给原来的前台应用。
///
/// 窗口只建一次、收起时 `orderOut` 而不销毁：重建一个全屏窗口连同它的
/// SwiftUI 视图树要 60ms 以上，而热键这条路径的预算是 150ms。
@MainActor
final class OverlayController {
    private let service: LibraryService
    private var window: OverlayWindow?
    private var hostingView: NSHostingView<OverlayView>?
    private var renderedSnapshot: LibrarySnapshot?
    private var hotKey: GlobalHotKey?
    private var escapeMonitor: Any?
    private var previousApp: NSRunningApplication?

    private(set) var isVisible = false

    init(service: LibraryService) {
        self.service = service
    }

    /// 覆盖层显隐变化的通知，供测试与调试观察。
    var onVisibilityChange: ((Bool) -> Void)?

    /// 注册 ⌥+Space 全局热键。注册失败（组合键被占用）时返回 false。
    @discardableResult
    func installHotKey() -> Bool {
        hotKey = GlobalHotKey(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey)
        ) { [weak self] in
            MainActor.assumeIsolated { self?.toggle() }
        }
        return hotKey != nil
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    /// 启动时先算一次快照，免得第一次按键落在冷路径上。
    func prewarm() {
        refresh()
    }

    func show() {
        guard !isVisible else { return }
        guard let screen = targetScreen() else { return }

        previousApp = NSWorkspace.shared.frontmostApplication

        let window = preparedWindow(for: screen)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        installEscapeMonitor()
        isVisible = true
        onVisibilityChange?(true)

        // 唤起路径上不读盘（ticket 017 的硬性要求）：先把窗口摆出来，
        // 再让重扫描在后台跑。清单多数时候没变，`render` 会因此什么都不做。
        refresh()
    }

    /// 单击一个方块的完整语义：启动该应用并收起覆盖层。
    func activate(_ entry: ApplicationEntry) {
        service.launch(entry)
        hide()
    }

    func hide() {
        guard isVisible else { return }

        let restoreFocusTo = previousApp
        hideWithoutRestoringFocus()
        // 把焦点还给唤起覆盖层之前的前台应用，否则用户回到原应用还得再点一次。
        _ = restoreFocusTo?.activate(options: [])
    }

    /// 收起覆盖层但不把焦点还回去。
    ///
    /// 从 Dock 图标进控制台时用它：接下来要开控制台窗口，
    /// 先把焦点还给别的应用再抢回来，中间会闪一下，还可能把控制台挤掉 key window。
    func hideWithoutRestoringFocus() {
        guard isVisible else { return }

        removeEscapeMonitor()
        window?.orderOut(nil)
        isVisible = false
        onVisibilityChange?(false)
        previousApp = nil
    }

    /// 覆盖层出现在**鼠标当前所在**的那块屏幕上。
    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let geometries = screens.map { screen in
            ScreenGeometry(
                identifier: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    .map { "\($0)" } ?? "unknown",
                frame: Rect(
                    origin: Point(x: screen.frame.origin.x, y: screen.frame.origin.y),
                    size: Size(width: screen.frame.width, height: screen.frame.height)
                )
            )
        }
        guard let index = ScreenSelector.indexOfScreen(containing: mouseLocation(), in: geometries) else {
            return nil
        }
        return screens[index]
    }

    /// `NSEvent.mouseLocation` 与 `NSScreen.frame` 同为"主屏左下角为原点、y 轴向上"的坐标系。
    private func mouseLocation() -> Point {
        let location = NSEvent.mouseLocation
        return Point(x: location.x, y: location.y)
    }

    /// 复用已建好的窗口，必要时把它挪到目标屏幕上。
    private func preparedWindow(for screen: NSScreen) -> OverlayWindow {
        let window = self.window ?? makeWindow(for: screen)
        self.window = window
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: false)
        }
        return window
    }

    /// 后台重算快照，回到主线程后再决定要不要重建视图。
    ///
    /// 扫描要读 100 多个 Info.plist，放主线程上就是一次可感知的卡顿。
    private func refresh() {
        let service = self.service
        Task.detached(priority: .utility) { [weak self] in
            let snapshot = service.snapshot()
            await MainActor.run { self?.render(snapshot) }
        }
    }

    /// 只在快照真的变了的时候重建视图树。
    ///
    /// 给 `rootView` 赋值会重跑整棵 SwiftUI 树；大多数唤起时应用清单没变，
    /// 那这笔开销就是白花的，而窗口里已有的画面本来就是要显示的内容。
    private func render(_ snapshot: LibrarySnapshot) {
        guard let hostingView, snapshot != renderedSnapshot else { return }
        hostingView.rootView = OverlayView(
            snapshot: snapshot,
            onLaunch: { [weak self] entry in self?.activate(entry) },
            onDismiss: { [weak self] in self?.hide() }
        )
        renderedSnapshot = snapshot
    }

    private func makeWindow(for screen: NSScreen) -> OverlayWindow {
        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Dock 是 20、菜单栏是 24、状态栏是 25；screenSaver（1000）足够盖过它们。
        window.level = .screenSaver
        // 必须能加入所有 Space 并覆盖全屏应用，否则在别的桌面或全屏应用前台时唤不出来。
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = false
        window.animationBehavior = .none

        let hostingView = NSHostingView(
            rootView: OverlayView(snapshot: LibrarySnapshot(groups: []), onLaunch: { _ in }, onDismiss: {})
        )
        self.hostingView = hostingView
        window.contentView = hostingView
        return window
    }

    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 先在非隔离上下文里判定按键，避免把 NSEvent 带进 @MainActor 闭包
            // （NSEvent 不是 Sendable）。
            guard event.keyCode == UInt16(kVK_Escape) else { return event }
            MainActor.assumeIsolated { self?.hide() }
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }
}
