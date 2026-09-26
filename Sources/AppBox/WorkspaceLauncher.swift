import AppBoxCore
import AppKit

/// 用 LaunchServices 启动应用。
///
/// 已在运行时**激活已有实例**而不是再开一个：`open -n` 那类重复启动会让同一个
/// 应用出现两个 Dock 图标，且新实例往往没有可用的窗口。
struct WorkspaceLauncher: Launching {
    func launch(bundleIdentifier: String, path: String) {
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { !$0.isTerminated }) {
            running.activate(options: [.activateAllWindows])
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: path),
            configuration: configuration
        ) { _, error in
            if let error {
                NSLog("[AppBox] 启动 \(bundleIdentifier) 失败：\(error.localizedDescription)")
            }
        }
    }
}
