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
    /// 顶层 ↔ 子网格的导航状态。放在控制器里而不是视图里：视图树在快照变化时
    /// 会被整体重建，而 Esc 的判定在视图之外（键盘监听器）。
    private let model = OverlayModel()
    private var window: OverlayWindow?
    private var hostingView: NSHostingView<OverlayView>?
    /// 最近一次算出来的快照。与 `renderedSnapshot` 分开：窗口还没建的时候也得
    /// 留住它，否则首屏是一张空网格，要等扫描回来才填上。
    private var latestSnapshot: LibrarySnapshot?
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
        model.reset()

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
    /// 这里**不**记录应用位置——覆盖层这条路上一个字节都不写盘（ticket 017）。
    private func refresh() {
        let service = self.service
        Task.detached(priority: .utility) { [weak self] in
            let snapshot = service.snapshot()
            await MainActor.run { self?.apply(snapshot) }
        }
    }

    /// 换成一份新快照。
    ///
    /// 只在快照真的变了的时候重建视图树：给 `rootView` 赋值会重跑整棵 SwiftUI 树，
    /// 而大多数变更（比如某个应用的图标补上了）本就不影响画面。窗口自始至终是同一个，
    /// 覆盖层开着的时候也只是原地换内容，不会闪。
    func apply(_ snapshot: LibrarySnapshot) {
        latestSnapshot = snapshot
        // 打开着的分组可能在控制台里被删掉了，那层子网格得自己退掉。
        model.reconcile(with: snapshot)
        guard let hostingView, snapshot != renderedSnapshot else { return }
        hostingView.rootView = OverlayView(
            snapshot: snapshot,
            model: model,
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

        // 第一次建窗时用预热好的那份快照，首屏立刻有内容；随后后台再校一遍。
        let hostingView = NSHostingView(
            rootView: OverlayView(
                snapshot: latestSnapshot ?? LibrarySnapshot(groups: []),
                model: model,
                onLaunch: { _ in },
                onDismiss: {}
            )
        )
        renderedSnapshot = latestSnapshot
        self.hostingView = hostingView
        window.contentView = hostingView
        return window
    }

    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 先在非隔离上下文里判定按键，避免把 NSEvent 带进 @MainActor 闭包
            // （NSEvent 不是 Sendable）。
            guard event.keyCode == UInt16(kVK_Escape) else { return event }
            // 子网格里 Esc 先回顶层，顶层才轮到收起覆盖层。
            MainActor.assumeIsolated {
                guard let self, !self.model.back() else { return }
                self.hide()
            }
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
