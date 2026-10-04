import AppBoxCore
import SwiftUI

/// 左栏里的一行工具。
struct ToolRow: View {
    let tool: ToolIdentifier

    var body: some View {
        Label {
            Text(tool.displayName)
                // 没实现的置灰，让用户一眼看出这一项还不能用——
                // 点了没反应比这一项不存在更糟。
                .foregroundStyle(tool.isImplemented ? .primary : .secondary)
        } icon: {
            Image(systemName: tool.systemImage)
                .foregroundStyle(tool.isImplemented ? .primary : .tertiary)
        }
    }
}

/// 右栏的工具工作区：按工具分发。
///
/// 选中项的同步放在这里而不是左栏的 `onChange`：`ToolboxModel` 需要知道
/// 「现在在用哪个工具」才能决定重算谁（页面出现时它就该开始算，而不是等用户再点一下）。
/// 用 `.task(id:)` 而不是 `onAppear`：`id` 变了会重跑，切工具时自然重新计算。
struct ToolDetailView: View {
    let tool: ToolIdentifier
    var model: ToolboxModel

    var body: some View {
        Group {
            if !tool.isImplemented {
                UnimplementedToolView(tool: tool)
            } else {
                switch tool {
                case .jsonFormatter:
                    JSONToolView(model: model)
                case .qrCode:
                    QRCodeToolView(model: model)
                default:
                    UnimplementedToolView(tool: tool)
                }
            }
        }
        .task(id: tool) {
            // 切到某个工具时才认它是当前工具：这样 `ToolboxModel` 里现有的输入
            // 会被拿来重算，而不是清空。用户切走再切回，内容原样还在。
            guard tool.isImplemented else { return }
            model.selectedTool = tool
            model.recompute(tool)
        }
    }
}
