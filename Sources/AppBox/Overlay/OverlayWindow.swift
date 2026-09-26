import AppKit

/// 无边框窗口默认既不能成为 key window 也不能成为 main window，因而收不到键盘事件。
/// 覆盖层需要键盘导航与 Esc 退出，所以必须放开这两个开关。
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
