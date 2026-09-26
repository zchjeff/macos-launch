import AppBoxCore
import AppKit
import SwiftUI

/// 进程入口。
///
/// 单独抽出 `main` 是为了让调试命令在 SwiftUI 启动之前就返回——
/// 否则 `WindowGroup` 会先闪一下窗口再退出。
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
        AppBoxApp.main()
    }
}

struct AppBoxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(AppBoxIdentity.displayName) {
            PlaceholderWindowView(overlay: appDelegate.overlay)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let overlay = OverlayController(service: .live())

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !overlay.installHotKey() {
            NSLog("[AppBox] ⌥+Space 注册失败，可能已被其他应用占用")
        }
        overlay.prewarm()
    }

    /// 关掉窗口不等于退出——热键必须继续可用。
    /// 应用是常驻的，退出入口在控制台里（013 提供）。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// 001 留下的占位窗口。010 会把它换成真正的控制台。
struct PlaceholderWindowView: View {
    let overlay: OverlayController

    var body: some View {
        VStack(spacing: 14) {
            Text(AppBoxIdentity.displayName)
                .font(.largeTitle)
            Text("版本 \(AppBoxIdentity.version)")
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            Text("按 ⌥+Space 唤起覆盖层（鼠标在哪块屏就出现在哪块屏）")
                .font(.callout)
                .multilineTextAlignment(.center)
            Button("切换覆盖层") { overlay.toggle() }

            Text("关闭本窗口不会退出 AppBox")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 460, height: 320)
    }
}
