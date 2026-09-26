import AppBoxCore
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 覆盖层的生命周期与窗口配置。
///
/// 唤起瞬间判定目标屏幕、创建窗口、抢焦点；收起时把焦点还给原来的前台应用。
@MainActor
final class OverlayController {
    private var window: OverlayWindow?
    private var hotKey: GlobalHotKey?
    private var escapeMonitor: Any?
    private var previousApp: NSRunningApplication?

    private(set) var isVisible = false

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

    func show() {
        guard !isVisible else { return }
        guard let screen = targetScreen() else { return }

        previousApp = NSWorkspace.shared.frontmostApplication

        let window = makeWindow(for: screen)
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        installEscapeMonitor()
        isVisible = true
        onVisibilityChange?(true)
    }

    func hide() {
        guard isVisible else { return }

        removeEscapeMonitor()
        window?.orderOut(nil)
        window = nil
        isVisible = false
        onVisibilityChange?(false)

        // 把焦点还给唤起覆盖层之前的前台应用，否则用户回到原应用还得再点一次。
        _ = previousApp?.activate(options: [])
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
        window.contentView = NSHostingView(
            rootView: OverlayView { [weak self] in self?.hide() }
        )
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
