import AppBoxCore
import AppKit

/// 进程入口。
///
/// 不走 SwiftUI 的 `App` / `Scene`：`WindowGroup` 会在启动时自动开一个窗口，
/// 而 AppBox 启动时只该静默常驻（010 的验收标准），窗口由 `AppDelegate` 自己管。
/// 单独抽出 `main` 也是为了让调试命令在 `NSApplication.run()` 之前就返回。
@main
enum EntryPoint {
    static func main() {
        if CommandLine.arguments.contains("--scan") {
            ScanCommand.run()
            return
        }
        if CommandLine.arguments.contains("--config") {
            ConfigCommand.run()
            return
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        // 不设 `.regular` 的话，直接跑可执行文件（没有 .app 外壳时）不会出现在 Dock 里，
        // 也就点不到控制台入口。
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 覆盖层与控制台共用同一个服务：配置是它持有的状态，
    /// 两边各建一个实例就会出现「控制台改完了，覆盖层还按旧的渲染」。
    private let service: LibraryService
    private let overlay: OverlayController
    private let console: ConsoleWindowController

    override init() {
        let service = LibraryService.live()
        self.service = service
        overlay = OverlayController(service: service)
        console = ConsoleWindowController(service: service)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        if !overlay.installHotKey() {
            NSLog("[AppBox] ⌥+Space 注册失败，可能已被其他应用占用")
        }
        // 先把快照算出来，免得第一次按键落在冷扫描上。
        overlay.prewarm()
    }

    /// 点 Dock 图标开控制台。
    ///
    /// 先收起覆盖层：它在 `.screenSaver` 层级，留着会把刚打开的控制台整个盖住。
    /// 走不还焦点的那条收起路径，免得焦点先还给别的应用再抢回来、中间闪一下。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        overlay.hideWithoutRestoringFocus()
        console.show()
        return true
    }

    /// 关掉窗口不等于退出——热键必须继续可用。
    /// 应用是常驻的，退出入口在控制台里（013 提供）。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 程序自己的主菜单。
    ///
    /// 没有它就没有 ⌘Q；更要紧的是文本框里的 ⌘C/⌘V 也不会响应——
    /// AppKit 的编辑命令靠菜单项沿响应链派发，不是文本框自带的。
    private func installMainMenu() {
        let name = AppBoxIdentity.displayName

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "关于 \(name)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let mainMenu = NSMenu()
        for (title, submenu) in [(name, appMenu), ("编辑", editMenu)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu
    }
}
