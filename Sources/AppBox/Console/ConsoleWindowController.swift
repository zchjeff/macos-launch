import AppBoxCore
import AppKit
import SwiftUI

/// 控制台窗口的生命周期。
///
/// 与覆盖层不同，控制台是常规窗口：有标题栏、能被拖动缩放、关掉不销毁——
/// 下次点 Dock 图标直接复用，视图模型里选中的分组和列表滚动位置都还在。
@MainActor
final class ConsoleWindowController {
    private let model: ConsoleModel
    private var window: NSWindow?

    init(service: LibraryService) {
        model = ConsoleModel(service: service)
    }

    /// 每次打开都重读一遍分组结构：控制台关着的时候，覆盖层那边可能已经拖过了。
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        Task { await model.refresh() }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppBoxIdentity.displayName
        window.contentMinSize = NSSize(width: 720, height: 440)
        // 控制器一直持有这个窗口，关掉只是 orderOut；不关掉这个开关，
        // AppKit 会在 close 时把窗口释放掉，再打开就是访问已释放对象。
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ConsoleView(model: model))
        window.center()
        // 记住用户摆的位置和调的大小，下次打开还在那儿。
        window.setFrameAutosaveName("AppBoxConsole")
        return window
    }
}
