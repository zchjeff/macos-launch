# 用 SwiftUI + SwiftPM 构建，不依赖 Xcode 工程

**状态**：accepted（2026-09-26 修订）

决定用 Swift 6 + SwiftUI 编写，`swift build` 命令行编译，再用脚本把二进制组装成 `.app` 包。不使用 `.xcodeproj`。

## 修订记录

**2026-09-26**：原始理由已失效——决策时开发机只装了 CommandLineTools，而实现阶段 Xcode.app（3.7G）被安装到了 `/Applications`。重新评估后**维持原决策**，理由更新为：SwiftPM 包可以直接用 Xcode 打开（双击 `Package.swift`），照样能获得 SwiftUI 实时预览与断点调试，不需要维护 `.xcodeproj`；而 `.xcodeproj` 会带来工程文件难 diff、与「脚本组装 .app」方案职责重叠的问题。原始理由保留在下方，供追溯。

## 备选方案

- **标准 Xcode 工程**：图形化管理 Info.plist / entitlements / 资源目录、一键打包、图形化签名。代价是工程文件结构复杂、不好 diff。既然 SwiftPM 包也能在 Xcode 里打开调试，这些收益不足以抵消成本。
- **Electron/Tauri + Web 前端**：获取系统图标需自行解析 `.icns`，全屏覆盖层的窗口层级与焦点控制困难，内存占用高。与「启动台」的性能目标（唤起 < 150ms）冲突。

## 后果

- `.app` 组装、`Info.plist` 生成、代码签名都由 `scripts/build-app.sh` 维护
- 对外分发时若需要公证，需补 Xcode 工具链与签名证书
- 开发时用 `swift build` / `swift test`；需要实时预览或断点调试时用 Xcode 打开 `Package.swift`
