import AppBoxCore
import SwiftUI

/// 控制台主界面：左边是分组（外加「失效应用」那一栏），右边是这个分组里的应用。
///
/// 这里只做「把控件接到 `ConsoleModel` 上」。所有判断——能不能删、删了会怎样、
/// 失败了说什么——都在模型里，那部分有单元测试兜着。
struct ConsoleView: View {
    @Bindable var model: ConsoleModel

    @State private var nameEntry: NameEntry?

    /// 应用行的固定高度。
    ///
    /// 「落点在行内偏上还是偏下」决定插到目标前面还是后面，
    /// 而那个判断要把落点的 y 跟行高比。行高随内容变的话这个判断就飘了，
    /// 所以这里写死，`ApplicationRow` 按它撑开。
    private static let rowHeight: CGFloat = 44

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
                .confirmationDialog(
                    "删除分组",
                    isPresented: deleteConfirmation,
                    presenting: model.pendingDeletion
                ) { snapshot in
                    Button("删除「\(snapshot.group.name)」", role: .destructive) {
                        Task { await model.confirmDelete() }
                    }
                    Button("取消", role: .cancel) { model.cancelDelete() }
                } message: { _ in
                    Text(model.deleteConfirmationMessage ?? "")
                }
        } detail: {
            detail
        }
        .inspector(isPresented: isShowingDetail) {
            if let detail = model.detail {
                ApplicationInspector(
                    detail: detail,
                    model: model,
                    onEditAlias: { nameEntry = .alias(detail) }
                )
                .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
            }
        }
        .sheet(item: $nameEntry) { entry in
            NameEntrySheet(entry: entry) { name in
                Task {
                    switch entry {
                    case .create:
                        await model.createGroup(named: name)
                    case .rename(let group):
                        await model.rename(group.id, to: name)
                    case .alias(let detail):
                        await model.setAlias(name, for: detail.bundleIdentifier)
                    }
                }
            }
        }
        .sheet(isPresented: setupPresentation) {
            if let setup = model.setup {
                SetupWizardView(model: setup) {
                    Task { await model.endSetup() }
                }
            }
        }
        .alert("操作失败", isPresented: isShowingError) {
            Button("知道了") { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - 左侧：分组与失效

    private var sidebar: some View {
        List(selection: $model.selection) {
            Section("分组") {
                ForEach(model.groups) { snapshot in
                    GroupRow(snapshot: snapshot)
                        .tag(ConsoleSelection.group(snapshot.group.id))
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("重命名…") { nameEntry = .rename(snapshot.group) }
                                .disabled(snapshot.group.isUngrouped)
                            Divider()
                            Button("删除…", role: .destructive) {
                                model.requestDelete(snapshot.group.id)
                            }
                            .disabled(snapshot.group.isUngrouped)
                        }
                        // 从右侧把应用拖到这一行上就移入该组。
                        .guardedDropDestination(for: ApplicationDragPayload.self) { payload, _ in
                            Task { await model.move(payload.bundleIdentifier, toGroup: snapshot.group.id) }
                            return true
                        }
                }
                .onMove { source, destination in
                    Task { await model.moveGroups(fromOffsets: source, toOffset: destination) }
                }
            }

            // 只有真的有失效记录时才出现：平时它是噪音，出问题时它得一眼看得见。
            if !model.missing.isEmpty {
                Section("维护") {
                    MissingGroupRow(count: model.missing.count)
                        .tag(ConsoleSelection.missing)
                        .contentShape(Rectangle())
                }
            }
        }
        .safeAreaInset(edge: .bottom) { addGroupBar }
    }

    private var addGroupBar: some View {
        HStack {
            Button {
                nameEntry = .create
            } label: {
                Label("新建分组", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - 右侧

    @ViewBuilder
    private var detail: some View {
        if case .missing = model.selection {
            MissingApplicationsView(model: model)
        } else if let group = model.selectedGroup {
            groupDetail(for: group)
        } else {
            ProgressView("正在读取应用列表…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func groupDetail(for group: AppBoxCore.Group) -> some View {
        VStack(spacing: 0) {
            detailHeader(for: group)
            Divider()
            if model.applications.isEmpty {
                emptyGroupHint(for: group)
            } else {
                applicationList
            }
            Divider()
            detailFooter
        }
    }

    private func detailHeader(for group: AppBoxCore.Group) -> some View {
        HStack(spacing: 8) {
            Image(systemName: group.isUngrouped ? "tray" : "folder")
                .foregroundStyle(.secondary)
            Text(group.name).font(.headline)
            Text(applicationCountSummary)
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

    /// 把「几个已隐藏」一并说出来：列表里有几行是半透明的，得让人知道那是为什么。
    private var applicationCountSummary: String {
        let hidden = model.applications.filter(\.isHidden).count
        let total = model.applications.count
        return hidden == 0 ? "\(total) 个应用" : "\(total) 个应用（\(hidden) 个已隐藏）"
    }

    private func emptyGroupHint(for group: AppBoxCore.Group) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "square.dashed")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(group.isUngrouped ? "应用都归好位了" : "「\(group.name)」还是空的")
                .foregroundStyle(.secondary)
            if !group.isUngrouped {
                Text("在左侧选中别的分组，把应用拖到「\(group.name)」这一行上即可移入。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var applicationList: some View {
        List(model.applications, selection: $model.selectedApplicationID) { entry in
            row(for: entry)
                .tag(entry.bundleIdentifier)
        }
    }

    /// 锁定与隐藏的应用行。
    ///
    /// 锁定的行不给拖：拖了也不会动（位置由服务保证），给一个能拖的手感反而是骗人。
    /// 隐藏的行照样能拖——隐藏只是不在覆盖层露面，用户照样可以把它挪个地方。
    @ViewBuilder
    private func row(for entry: ApplicationEntry) -> some View {
        draggableRow(for: entry)
            // 从右侧把应用拖到左侧的分组上就移入该组；
            // 拖到另一行上则插到它的前面或后面。
            .guardedDropDestination(for: ApplicationDragPayload.self) { payload, location in
                let placeAfter = location.y > Self.rowHeight / 2
                Task {
                    await model.move(
                        payload.bundleIdentifier,
                        onto: entry.bundleIdentifier,
                        placeAfter: placeAfter
                    )
                }
                return true
            }
    }

    /// 拖拽源接线。收在落点里层：反过来会让系统级 Esc 取消被吞掉
    /// （同覆盖层格子，真机探针定位）。
    @ViewBuilder
    private func draggableRow(for entry: ApplicationEntry) -> some View {
        let row = ApplicationRow(entry: entry, height: Self.rowHeight)

        if entry.isLocked {
            row
        } else {
            row.draggable(ApplicationDragPayload(bundleIdentifier: entry.bundleIdentifier))
        }
    }

    private var detailFooter: some View {
        Text("拖动应用调整组内顺序；拖到左侧的分组上则移入那个分组。选中一行可在右侧改别名、隐藏或锁定。")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
    }

    // MARK: - 绑定

    private var deleteConfirmation: Binding<Bool> {
        Binding(
            get: { model.pendingDeletion != nil },
            set: { if !$0 { model.cancelDelete() } }
        )
    }

    private var isShowingDetail: Binding<Bool> {
        Binding(
            get: { model.detail != nil },
            // 关掉详情面板就等于取消选中，下次点开的是用户刚点的那一行。
            set: { if !$0 { model.selectedApplicationID = nil } }
        )
    }

    private var isShowingError: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.dismissError() } }
        )
    }

    /// 引导整理由控制台承载：首启打开控制台时就挂在上面，走完自己摘掉。
    private var setupPresentation: Binding<Bool> {
        Binding(
            get: { model.setup != nil },
            // 没点「确认」也没点「取消」就把它关掉：什么都不写，下次启动再说。
            set: { if !$0 { model.dismissSetup() } }
        )
    }
}

private struct GroupRow: View {
    let snapshot: GroupSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: snapshot.group.isUngrouped ? "tray" : "folder")
                .foregroundStyle(.secondary)
            Text(snapshot.group.name)
            Spacer(minLength: 8)
            Text("\(snapshot.applications.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }
}

private struct MissingGroupRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.folder")
                .foregroundStyle(.secondary)
            Text("失效应用")
            Spacer(minLength: 8)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }
}

private struct ApplicationRow: View {
    let entry: ApplicationEntry
    let height: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName).lineLimit(1)
                Text(entry.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if entry.isHidden {
                Image(systemName: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("已隐藏：不出现在覆盖层")
            }
            if entry.isLocked {
                Image(systemName: "lock")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("已锁定：位置不被排序改动")
            }
        }
        // 隐藏的行压暗一点，一眼能看出它跟别的不一样。
        .opacity(entry.isHidden ? 0.55 : 1)
        .frame(height: height)
    }

    @ViewBuilder
    private var icon: some View {
        if let image = entry.iconCachePath.flatMap(IconImageStore.image(atPath:)) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
    }
}

/// 正在输入名字的那件事：新建一个分组、给某个分组改名，或者给某个应用起个别名。
private enum NameEntry: Identifiable {
    case create
    case rename(AppBoxCore.Group)
    case alias(ApplicationDetail)

    var id: String {
        switch self {
        case .create: "create"
        case .rename(let group): "rename-\(group.id)"
        case .alias(let detail): "alias-\(detail.bundleIdentifier)"
        }
    }

    var title: String {
        switch self {
        case .create: "新建分组"
        case .rename: "重命名分组"
        case .alias: "设置别名"
        }
    }

    var prompt: String {
        switch self {
        case .create, .rename: "分组名"
        case .alias: "留空表示不用别名"
        }
    }

    var initialName: String {
        switch self {
        case .create: ""
        case .rename(let group): group.name
        case .alias(let detail): detail.alias ?? ""
        }
    }
}

private struct NameEntrySheet: View {
    let entry: NameEntry
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry.title).font(.headline)
            TextField(entry.prompt, text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("确定", action: commit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { name = entry.initialName }
    }

    private func commit() {
        onCommit(name)
        dismiss()
    }
}
