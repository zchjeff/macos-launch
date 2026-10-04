import AppBoxCore
import SwiftUI

/// 控制台里的设置面板。
///
/// 全局设置（013）后续几片也往这里加：唤起热键、网格行列与图标尺寸、背景模糊度。
/// 入口在窗口工具栏右上角的齿轮，以及 App 菜单里的「设置…」（⌘,）。
struct ConsoleSettingsView: View {
    /// 开机启动的开关直接接到控制台模型上：它读的是系统真值（`SMAppService`），
    /// 注册失败会弹回并给出说法——这一层不做任何乐观假设。
    let model: ConsoleModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置")
                .font(.headline)

            section("通用") {
                Toggle("开机启动", isOn: openAtLoginBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Text("开启后 AppBox 会随登录启动常驻，⌥+Space 热键才能一直可用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .glassActionButton(prominent: true)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.5), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }

    /// 开关读的是模型缓存的系统状态；拨动后模型会按端口回填真值。
    private var openAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.isOpenAtLogin },
            set: { model.setOpenAtLogin($0) }
        )
    }
}
