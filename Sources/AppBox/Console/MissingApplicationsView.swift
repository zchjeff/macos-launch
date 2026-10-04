import AppBoxCore
import SwiftUI

/// 「失效应用」这一栏：配置里记着、磁盘上已经找不到的那些应用。
///
/// 只做手动清理——自动标记失效要等 014 的增量同步落地。
struct MissingApplicationsView: View {
    @Bindable var model: ConsoleModel

    private static let rowHeight: CGFloat = 44

    var body: some View {
        // 与分组详情同一套：上下两条玻璃控制条浮着，列表从它们底下滚过去。
        GlassGroup(spacing: 12) {
            content
                .safeAreaInset(edge: .top, spacing: 0) { header }
                .safeAreaInset(edge: .bottom, spacing: 0) { footer }
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

    @ViewBuilder
    private var content: some View {
        if model.missing.isEmpty {
            emptyHint
        } else {
            list
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
        // 顶栏玻璃：列表从它底下滚过去。
        .glassSurface(.floating, in: .rect(cornerRadius: 16), fallback: .bar)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
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
        // 列表滚到上下两条玻璃底下时，边缘柔化（macOS 26+）。
        .glassScrollEdge([.top, .bottom])
    }

    private var footer: some View {
        Text("这些应用在配置里，但磁盘上已经找不到。清理只是让 AppBox 忘掉它的设置，不会删除任何东西。")
            .font(.caption)
            // 玻璃底上抬到 .secondary，保持可读。
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .glassSurface(.floating, in: .rect(cornerRadius: 16), fallback: .bar)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 10)
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
