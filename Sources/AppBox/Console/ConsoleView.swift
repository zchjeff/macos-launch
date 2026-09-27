import AppBoxCore
import SwiftUI

/// 控制台主界面：左边是分组（外加「失效应用」那一栏），右边是这个分组里的应用网格。
///
/// 这里只做「把控件接到 `ConsoleModel` 上」。所有判断——能不能删、删了会怎样、
/// 失败了说什么——都在模型里，那部分有单元测试兜着。
struct ConsoleView: View {
    @Bindable var model: ConsoleModel

    @State private var nameEntry: NameEntry?

    /// 瓦片的边长（图标容器，不含名字）。
    ///
    /// 「落点在瓦片偏左还是偏右」决定插到目标前面还是后面，
    /// 而那个判断要把落点的 x 跟瓦片宽比。瓦片宽随内容变的话这个判断就飘了，
    /// 所以这里写死，`ApplicationTile` 按它撑开。
    private static let tileSize: CGFloat = 96

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
            Toggle("开机启动", isOn: openAtLoginBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// 开关读的是模型缓存的系统状态；拨动后模型会按端口回填真值，
    /// 注册失败时开关弹回、同时弹错误说明。
    private var openAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.isOpenAtLogin },
            set: { model.setOpenAtLogin($0) }
        )
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
            if model.applications.isEmpty {
                emptyGroupHint(for: group)
            } else if model.filteredApplications.isEmpty {
                noMatchHint
            } else {
                applicationGrid
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
            Spacer(minLength: 12)
            searchField
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// 组内即时过滤：输入即筛，命中规则与覆盖层搜索同一套（含拼音）。
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索本组", text: $model.query)
                .textFieldStyle(.plain)
                .font(.callout)
                .frame(width: 160)
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.background))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    private var noMatchHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("没有匹配「\(model.query)」的应用")
                .foregroundStyle(.secondary)
            Button("清除搜索") { model.query = "" }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var applicationGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Self.tileSize, maximum: 112), spacing: 24)],
                spacing: 24
            ) {
                ForEach(model.filteredApplications) { entry in
                    tile(for: entry)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    /// 一个瓦片：选中、拖拽源、落点接在这里。
    ///
    /// 锁定的瓦片不给拖：拖了也不会动（位置由服务保证），给一个能拖的手感反而是骗人。
    /// 隐藏的瓦片照样能拖——隐藏只是不在覆盖层露面，用户照样可以把它挪个地方。
    private func tile(for entry: ApplicationEntry) -> some View {
        draggableTile(for: entry)
            // 落在瓦片左半边插到它前面、右半边插到后面——与覆盖层同一套语义。
            .guardedDropDestination(for: ApplicationDragPayload.self) { payload, location in
                let placeAfter = location.x > Self.tileSize / 2
                Task {
                    await model.move(
                        payload.bundleIdentifier,
                        onto: entry.bundleIdentifier,
                        placeAfter: placeAfter
                    )
                }
                return true
            }
            .contextMenu {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.selectFile(entry.path, inFileViewerRootedAtPath: "")
                }
                Divider()
                Button(entry.alias == nil ? "设置别名…" : "修改别名…") {
                    nameEntry = .alias(ApplicationDetail(entry, groupName: model.selectedGroup?.name))
                }
                Button(entry.isHidden ? "取消隐藏" : "隐藏") {
                    Task { await model.setHidden(!entry.isHidden, for: entry.bundleIdentifier) }
                }
                Button(entry.isLocked ? "解锁位置" : "锁定位置") {
                    Task { await model.setLocked(!entry.isLocked, for: entry.bundleIdentifier) }
                }
            }
    }

    /// 拖拽源接线。收在落点里层：反过来会让系统级 Esc 取消被吞掉
    /// （同覆盖层格子，真机探针定位）。
    @ViewBuilder
    private func draggableTile(for entry: ApplicationEntry) -> some View {
        if entry.isLocked {
            tileView(for: entry)
        } else {
            tileView(for: entry).draggable(ApplicationDragPayload(bundleIdentifier: entry.bundleIdentifier))
        }
    }

    @ViewBuilder
    private func tileView(for entry: ApplicationEntry) -> some View {
        ConsoleApplicationTile(
            entry: entry,
            side: Self.tileSize,
            isSelected: model.selectedApplicationID == entry.bundleIdentifier
        ) {
            model.selectedApplicationID = entry.bundleIdentifier
        }
    }

    /// 状态行：计数与隐藏数在过滤时同时说「命中几 / 共几」，不误报总数。
    private var detailFooter: some View {
        HStack(spacing: 8) {
            Text(countSummary)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Text("拖动调整顺序；拖到左侧分组则移入。")
                .font(.caption)
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var countSummary: String {
        let hidden = model.applications.filter(\.isHidden).count
        let total = model.applications.count
        let shown = model.filteredApplications.count
        let base: String
        if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            base = "\(total) 个应用"
        } else {
            base = "命中 \(shown) / 共 \(total)"
        }
        return hidden == 0 ? base : "\(base)（\(hidden) 个已隐藏）"
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

/// 控制台网格里的一个应用瓦片：图标容器 + 名字，带悬停浮起与选中环。
///
/// 外观与覆盖层的格子同语言（圆角容器、悬停加亮、强调色环），
/// 尺寸收敛一档：控制台是管理，覆盖层是启动。
private struct ConsoleApplicationTile: View {
    let entry: ApplicationEntry
    let side: CGFloat
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 6) {
            iconContainer
            Text(entry.displayName)
                .font(.caption)
                .lineLimit(1)
                .frame(width: side + 16)
        }
        .opacity(entry.isHidden ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.displayName)
        .accessibilityValue(accessibilityState)
    }

    private var iconContainer: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.opacity(isHovering || isSelected ? 0.9 : 0.55))
                .overlay {
                    Image(nsImage: iconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: side * 2 / 3, height: side * 2 / 3)
                }
                .overlay {
                    badges
                }
                .frame(width: side, height: side)
                .shadow(
                    color: .black.opacity(isHovering ? 0.18 : 0.08),
                    radius: isHovering ? 6 : 2,
                    y: isHovering ? 3 : 1
                )
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
        }
        .scaleEffect(isHovering ? 1.03 : 1)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
    }

    private var iconImage: NSImage {
        if let path = entry.iconCachePath, let image = IconImageStore.image(atPath: path) {
            return image
        }
        return NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
            ?? NSImage();
    }

    /// 隐藏与锁定的角标收在容器右上角，不再挤占名字行。
    private var badges: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 2) {
                    if entry.isHidden {
                        badge("eye.slash", help: "已隐藏：不出现在覆盖层")
                    }
                    if entry.isLocked {
                        badge("lock.fill", help: "已锁定：位置不被排序改动")
                    }
                }
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.background.opacity(0.85))
                )
                .offset(x: 4, y: -4)
            }
            Spacer()
        }
    }

    private func badge(_ symbol: String, help: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .help(help)
    }

    private var accessibilityState: String {
        var parts: [String] = []
        if entry.isHidden { parts.append("已隐藏") }
        if entry.isLocked { parts.append("已锁定") }
        if isSelected { parts.append("已选中") }
        return parts.joined(separator: "，")
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
