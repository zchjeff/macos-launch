import AppBoxCore
import SwiftUI

/// 应用详情面板：这个应用是谁、在哪、归哪一组，以及显示层的那几个开关。
///
/// 在场应用与失效记录共用这一套面板：失效的那几个只有 bundleID 与最后待过的位置，
/// 把读不出来的字段写成「—」就够了，不必为它单画一屏。
struct ApplicationInspector: View {
    let detail: ApplicationDetail
    let model: ConsoleModel
    let onEditAlias: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                identity
                Divider()
                flags
                Divider()
                alias
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 4) {
                Text(detail.alias ?? detail.realName ?? detail.bundleIdentifier)
                    .font(.headline)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if detail.isMissing {
                    Label("已失效", systemImage: "questionmark.folder")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if detail.isHidden {
                    Label("已隐藏", systemImage: "eye.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let image = detail.iconCachePath.flatMap(IconImageStore.image(atPath:)) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 48, height: 48)
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
                .frame(width: 48, height: 48)
        }
    }

    // MARK: - 身份

    private var identity: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("真实名称", detail.realName)
            field("bundleID", detail.bundleIdentifier, monospaced: true)
            field(detail.isMissing ? "最后待过的位置" : "路径", detail.lastKnownPath, monospaced: true)
            field("所属分组", detail.groupName)
        }
    }

    private func field(_ title: String, _ value: String?, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(monospaced ? .caption.monospaced() : .callout)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }

    // MARK: - 开关

    private var flags: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlagRow(
                title: "在覆盖层隐藏",
                systemImage: "eye.slash",
                isOn: detail.isHidden,
                toggle: toggle(\.isHidden) { await model.setHidden($0, for: detail.bundleIdentifier) }
            )
            FlagRow(
                title: "锁定组内位置",
                systemImage: "lock",
                isOn: detail.isLocked,
                toggle: toggle(\.isLocked) { await model.setLocked($0, for: detail.bundleIdentifier) }
            )
            FlagRow(
                title: "已失效",
                systemImage: "questionmark.folder",
                isOn: detail.isMissing,
                toggle: nil
            )
        }
    }

    /// 失效的记录改不了状态（它已经不在磁盘上了），那就只显示值，不给开关。
    private func toggle(
        _ value: KeyPath<ApplicationDetail, Bool>,
        set: @escaping (Bool) async -> Void
    ) -> Binding<Bool>? {
        guard !detail.isMissing else { return nil }
        return Binding(
            get: { detail[keyPath: value] },
            set: { newValue in Task { await set(newValue) } }
        )
    }

    // MARK: - 别名

    private var alias: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("别名")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(detail.alias ?? "未设置")
                    .foregroundStyle(detail.alias == nil ? .tertiary : .primary)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button(detail.alias == nil ? "设置…" : "修改…", action: onEditAlias)
                    .buttonStyle(.borderless)
                if detail.alias != nil {
                    Button("清除") {
                        Task { await model.setAlias(nil, for: detail.bundleIdentifier) }
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

private struct FlagRow: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    /// 给了就显示开关，不给就只显示状态。
    let toggle: Binding<Bool>?

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 8)
            if let toggle {
                Toggle("", isOn: toggle)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            } else {
                Text(isOn ? "是" : "否")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
