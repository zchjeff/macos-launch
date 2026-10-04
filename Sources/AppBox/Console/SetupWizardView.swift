import AppBoxCore
import SwiftUI

/// 引导整理：把推导出来的分组建议摆给用户看，改到他点头为止。
///
/// 这里只做「把控件接到 `SetupWizardModel` 上」：改名会不会重、删掉之后应用去哪、
/// 确认会写出什么，都在模型里，那部分有单元测试兜着。
struct SetupWizardView: View {
    let model: SetupWizardModel
    let onFinish: () -> Void

    @State private var renaming: SetupSuggestion?

    var body: some View {
        // 向导的上下两条控制条做成玻璃，建议列表从它们底下滚过去。
        GlassGroup(spacing: 12) {
            content
                .safeAreaInset(edge: .top, spacing: 0) { header }
                .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        }
        .frame(width: 720, height: 580)
        // 向导是个得先做决定的地方：关掉它不会替你写配置，但也别留下半截状态。
        // 要退出请走「取消」或「确认整理」——这两条路都会把配置文件落实。
        .interactiveDismissDisabled()
        .sheet(item: $renaming) { suggestion in
            SetupRenameSheet(name: suggestion.name) { model.rename(suggestion.id, to: $0) }
        }
        .alert("操作失败", isPresented: isShowingError) {
            Button("知道了") { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("先按类别分一分")
                .font(.title3.weight(.semibold))
            Text("这些建议来自每个应用自报的类别，一定是粗糙的。改名、并到别的组、删掉都行——"
                + "条越长的组越大，最大的那几条通常还得你自己再拆。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        // 说明文字浮在建议列表之上：玻璃，但保持文字本身是 .primary / .secondary。
        .glassSurface(.floating, in: .rect(cornerRadius: 16), fallback: .bar)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var content: some View {
        if model.suggestions.isEmpty {
            emptyHint
        } else {
            List {
                ForEach(model.suggestions) { suggestion in
                    SuggestionRow(
                        suggestion: suggestion,
                        isSkipped: model.isSkipped(suggestion.id),
                        maxCount: maxCount,
                        others: model.suggestions.filter { $0.id != suggestion.id },
                        onRename: { renaming = suggestion },
                        onMerge: { model.merge(suggestion.id, into: $0) },
                        onToggleSkip: {
                            model.isSkipped(suggestion.id)
                                ? model.restore(suggestion.id)
                                : model.skip(suggestion.id)
                        },
                        onRemove: { model.remove(suggestion.id) }
                    )
                }
            }
            .listStyle(.inset)
            // 列表滚到上下两条玻璃底下时，边缘柔化（macOS 26+）。
            .glassScrollEdge([.top, .bottom])
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.dashed")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("建议都删光了").foregroundStyle(.secondary)
            Text("确认之后所有应用都留在「未分类」，可以在控制台里慢慢分。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.unrecognizedCategories.isEmpty {
                    Text(unrecognizedHint)
                        .font(.caption)
                        // 玻璃底上抬到 .secondary。
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button("取消") {
                Task {
                    if await model.cancel() { onFinish() }
                }
            }
            .glassActionButton()
            Button("确认整理") {
                Task {
                    if await model.confirm() { onFinish() }
                }
            }
            .keyboardShortcut(.defaultAction)
            // 整个向导的主操作：系统突出玻璃（旧系统回退成 borderedProminent）。
            .glassActionButton(prominent: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassSurface(.floating, in: .rect(cornerRadius: 16), fallback: .bar)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    private var summary: String {
        guard model.acceptedCount > 0 else {
            return "一条建议都不采纳：\(model.totalCount) 个应用都会留在「未分类」。"
        }
        return "采纳 \(model.acceptedCount) 条建议，\(model.assignedCount) 个应用归位；"
            + "\(model.unclassifiedCount) 个留在「未分类」。确认后才会写入配置。"
    }

    /// 认不出来的类别要说出来：应用没丢，但用户得知道它们为什么没进建议。
    private var unrecognizedHint: String {
        let shown = model.unrecognizedCategories.prefix(2).joined(separator: "、")
        let suffix = model.unrecognizedCategories.count > 2 ? " 等" : ""
        return "有 \(model.unrecognizedCategories.count) 个类别本程序还不认识（\(shown)\(suffix)），"
            + "这些应用先留在「未分类」。"
    }

    /// 最大的一组有多大——每行的长度条都按它取比例，谁大谁小一眼看得出来。
    private var maxCount: Int {
        model.suggestions.map(\.applications.count).max() ?? 0
    }

    private var isShowingError: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.dismissError() } }
        )
    }
}

private struct SuggestionRow: View {
    let suggestion: SetupSuggestion
    let isSkipped: Bool
    let maxCount: Int
    let others: [SetupSuggestion]
    let onRename: () -> Void
    let onMerge: (String) -> Void
    let onToggleSkip: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(suggestion.name).font(.headline)
                    Text("\(suggestion.applications.count) 个应用")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if isSkipped {
                        Text("已跳过")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                sizeBar
                Text(memberNames)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("改名、并入、跳过、删除")
        }
        .padding(.vertical, 6)
        .opacity(isSkipped ? 0.55 : 1)
        .contextMenu { actions }
    }

    private var sizeBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(Color.accentColor.opacity(0.6))
                    .frame(width: max(3, proxy.size.width * fraction))
            }
        }
        .frame(height: 5)
    }

    private var fraction: CGFloat {
        guard maxCount > 0 else { return 0 }
        return CGFloat(suggestion.applications.count) / CGFloat(maxCount)
    }

    private var memberNames: String {
        suggestion.applications.map(\.displayName).joined(separator: "、")
    }

    @ViewBuilder
    private var actions: some View {
        Button("重命名…", action: onRename)
        Menu("并入…") {
            ForEach(others) { other in
                Button(other.name) { onMerge(other.id) }
            }
        }
        .disabled(others.isEmpty)
        Divider()
        Button(isSkipped ? "恢复这一条" : "跳过这一条", action: onToggleSkip)
        Button("删除这一条", role: .destructive, action: onRemove)
    }
}

private struct SetupRenameSheet: View {
    let name: String
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重命名建议").font(.headline)
            TextField("分组名", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .glassActionButton()
                Button("确定", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .glassActionButton(prominent: true)
            }
        }
        .padding(20)
        .onAppear { draft = name }
    }

    private func commit() {
        onCommit(draft)
        dismiss()
    }
}
