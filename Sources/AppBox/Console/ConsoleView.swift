import AppBoxCore
import SwiftUI

/// 控制台主界面：左边是分组，右边是这个分组里的应用。
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
        .sheet(item: $nameEntry) { entry in
            GroupNameSheet(entry: entry) { name in
                Task {
                    if let groupID = entry.groupID {
                        await model.rename(groupID, to: name)
                    } else {
                        await model.createGroup(named: name)
                    }
                }
            }
        }
        .alert("操作失败", isPresented: isShowingError) {
            Button("知道了") { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - 左侧：分组

    private var sidebar: some View {
        List(selection: $model.selectedGroupID) {
            Section("分组") {
                ForEach(model.groups) { snapshot in
                    GroupRow(snapshot: snapshot)
                        .tag(snapshot.group.id)
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
                        .dropDestination(for: ApplicationDragPayload.self) { payloads, _ in
                            guard let payload = payloads.first else { return false }
                            Task { await model.move(payload.bundleIdentifier, toGroup: snapshot.group.id) }
                            return true
                        }
                }
                .onMove { source, destination in
                    Task { await model.moveGroups(fromOffsets: source, toOffset: destination) }
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

    // MARK: - 右侧：应用

    @ViewBuilder
    private var detail: some View {
        if let group = model.selectedGroup {
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
        } else {
            ProgressView("正在读取应用列表…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(for group: AppBoxCore.Group) -> some View {
        HStack(spacing: 8) {
            Image(systemName: group.isUngrouped ? "tray" : "folder")
                .foregroundStyle(.secondary)
            Text(group.name).font(.headline)
            Text("\(model.applications.count) 个应用")
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
        List {
            ForEach(model.applications) { entry in
                ApplicationRow(entry: entry, height: Self.rowHeight)
                    .draggable(ApplicationDragPayload(bundleIdentifier: entry.bundleIdentifier))
                    .dropDestination(for: ApplicationDragPayload.self) { payloads, location in
                        guard let payload = payloads.first else { return false }
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
        }
    }

    private var detailFooter: some View {
        Text("拖动应用调整组内顺序；拖到左侧的分组上则移入那个分组。")
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

    private var isShowingError: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.dismissError() } }
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
        }
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

/// 正在输入名字的那件事：新建一个分组，或者给某个分组改名。
private enum NameEntry: Identifiable {
    case create
    case rename(AppBoxCore.Group)

    var id: String {
        switch self {
        case .create: "create"
        case .rename(let group): "rename-\(group.id)"
        }
    }

    var title: String {
        switch self {
        case .create: "新建分组"
        case .rename: "重命名分组"
        }
    }

    var initialName: String {
        switch self {
        case .create: ""
        case .rename(let group): group.name
        }
    }

    /// 要改名的分组；新建时为 nil。
    var groupID: String? {
        switch self {
        case .create: nil
        case .rename(let group): group.id
        }
    }
}

private struct GroupNameSheet: View {
    let entry: NameEntry
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry.title).font(.headline)
            TextField("分组名", text: $name)
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
