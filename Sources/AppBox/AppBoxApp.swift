import AppBoxCore
import SwiftUI

@main
struct AppBoxApp: App {
    var body: some Scene {
        WindowGroup(AppBoxIdentity.displayName) {
            SkeletonView()
        }
    }
}

/// 001 的占位界面：只证明 AppBoxCore 被正确链接、窗口能开出来。
/// 真正的覆盖层在 002 替换掉它。
struct SkeletonView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text(AppBoxIdentity.displayName)
                .font(.largeTitle)
            Text("版本 \(AppBoxIdentity.version)")
                .foregroundStyle(.secondary)
            Text(AppBoxIdentity.bundleIdentifier)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .frame(width: 420, height: 260)
    }
}
