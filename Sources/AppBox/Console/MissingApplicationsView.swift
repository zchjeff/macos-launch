import AppBoxCore
import SwiftUI

/// 「失效应用」这一栏：配置里记着、磁盘上已经找不到的那些应用。
///
/// 只做手动清理——自动标记失效要等 014 的增量同步落地。
struct MissingApplicationsView: View {
    @Bindable var model: ConsoleModel

    private static let rowHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.missing.isEmpty {
                emptyHint
            } else {
                list
            }
            Divider()
            footer
        }
        .confirmationDialog(
            "清理失效记录",
            isPresented: forgetConfirmation,
            presenting: model.pendingForget
        ) { record in
            Button("清理「\(record.alias ?? record.bundleIdentifier)」", role: .destructive) {
                Task { await model.confirmForget() }
            }
            Button("取消", role: .cancel) { model.cancelForget() }
        } message: { _ in
            Text(model.forgetConfirmationMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.folder")
                .foregroundStyle(.secondary)
            Text("失效应用").font(.headline)
            Text("\(model.missing.count) 个")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("没有失效的应用")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List(model.missing, selection: $model.selectedApplicationID) { record in
            MissingApplicationRow(record: record, height: Self.rowHeight) {
                model.requestForget(record.bundleIdentifier)
            }
            .tag(record.bundleIdentifier)
            .contextMenu {
                Button("清理…", role: .destructive) { model.requestForget(record.bundleIdentifier) }
            }
        }
    }

    private var footer: some View {
        Text("这些应用在配置里，但磁盘上已经找不到。清理只是让 AppBox 忘掉它的设置，不会删除任何东西。")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
    }

    private var forgetConfirmation: Binding<Bool> {
        Binding(
            get: { model.pendingForget != nil },
            set: { if !$0 { model.cancelForget() } }
        )
    }
}

private struct MissingApplicationRow: View {
    let record: MissingApplication
    let height: CGFloat
    let onForget: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(record.alias ?? record.bundleIdentifier)
                    .lineLimit(1)
                // 名称可以用别名顶替，bundleID 与位置不能——认出它靠的就是这两样。
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button("清理…", action: onForget)
                .buttonStyle(.borderless)
        }
        .frame(height: height)
    }

    private var subtitle: String {
        guard let path = record.lastKnownPath else { return record.bundleIdentifier }
        return "\(record.bundleIdentifier) — \(path)"
    }
}
