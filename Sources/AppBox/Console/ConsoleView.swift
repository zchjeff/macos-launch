import AppBoxCore
import SwiftUI

/// 控制台主界面：左边是分组（外加「失效应用」那一栏），右边是这个分组里的应用网格。
///
/// 这里只做「把控件接到 `ConsoleModel` 上」。所有判断——能不能删、删了会怎样、
/// 失败了说什么——都在模型里，那部分有单元测试兜着。
struct ConsoleView: View {
    @Bindable var model: ConsoleModel
    /// 工具箱的状态。与 `ConsoleModel` 平级、由窗口控制器持有，
    /// 因此关掉控制台再打开，用户粘在工具里的内容还在（只有退出进程才忘）。
    var toolbox: ToolboxModel

    @State private var nameEntry: NameEntry?

    /// 侧栏分区的展开状态。
    ///
    /// 存在 `UserDefaults` 里而不是方案 JSON 里：折叠是「用户想怎么摆自己这一栏」，
    /// 与覆盖层读到的任何东西都无关，塞进配置只会让配置文件多一份与它无关的噪音。
    @AppStorage("console.sidebar.groupsExpanded") private var groupsExpanded = true
    @AppStorage("console.sidebar.toolsExpanded") private var toolsExpanded = true

    /// 瓦片的边长（图标容器，不含名字）。
    ///
    /// 「落点在瓦片偏左还是偏右」决定插到目标前面还是后面，
    /// 而那个判断要把落点的 x 跟瓦片宽比。瓦片宽随内容变的话这个判断就飘了，
    /// 所以这里写死，`ApplicationTile` 按它撑开。
    private static let tileSize: CGFloat = 96

    var body: some View {
        NavigationSplitView {
            // 侧栏的玻璃收在同一个容器里：间距统一，
            // 相邻的玻璃按钮与条形玻璃会各自成形，而不是糊成一块。
            GlassGroup(spacing: 12) {
                sidebar
            }
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
        .toolbar {
            // 设置入口固定在右上角。用 `primaryAction` 让它落进工具区右侧，
            // 不会被系统挪到标题旁边（那是 `navigation` 的位置）。
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.isShowingSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                .help("设置（⌘,）")
            }
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
        .sheet(isPresented: $model.isShowingSettings) {
            ConsoleSettingsView(model: model)
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
            // 「分组」整区可折叠：分组多了以后，用户往往只在分组与工具之间来回切，
            // 收起一区能把另一区顶到眼前。
            //
            // 分区标题的可见性跟着 `expanded` 走：系统默认只在「悬停且展开」时显示标题，
            // 收起后标题会消失，用户就找不到地方点回去了——所以这里显式指定。
            //
            // 分区头不可选中：`Section` 带上 `selection:` 之后自己也成了一行，
            // 点标题会把左栏的选中项清空，右侧跟着闪一下空白。
            //
            // ⚠️ `.selectionDisabled()` 必须只作用在「分区头视图」上，不能挂在 `Section` 上：
            // 挂在 Section 上会连分区里的每一行一起禁用选中，导致整栏点不动（历史 bug）。
            Section(isExpanded: $groupsExpanded) {
                ForEach(model.groups) { snapshot in
                    GroupRow(snapshot: snapshot)
                        .tag(ConsoleSelection.group(snapshot.group.id))
                        .contentShape(Rectangle())
                        .contextMenu {
                            // 新分组从这一行右键长出来：它要放进「分组」这件事里，
                            // 而这一行正是那件事本身。
                            Button("新建分组…") { nameEntry = .create }
                            Divider()
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
            } header: {
                SidebarSectionHeader(title: "分组")
                    .selectionDisabled()
            }

            // 只有真的有失效记录时才出现：平时它是噪音，出问题时它得一眼看得见。
            if !model.missing.isEmpty {
                Section {
                    MissingGroupRow(count: model.missing.count)
                        .tag(ConsoleSelection.missing)
                        .contentShape(Rectangle())
                } header: {
                    Text("维护")
                        .selectionDisabled()
                }
            }

            // 工具箱。与分组并列但互不相干：工具不读应用、不写配置（见 ADR-0007）。
            Section(isExpanded: $toolsExpanded) {
                ForEach(ToolIdentifier.allCases) { tool in
                    ToolRow(tool: tool)
                        .tag(ConsoleSelection.tool(tool))
                        .contentShape(Rectangle())
                }
            } header: {
                SidebarSectionHeader(title: "工具")
                    .selectionDisabled()
            }
        }
    }

    // MARK: - 右侧

    @ViewBuilder
    private var detail: some View {
        if case .tool(let tool) = model.selection {
            ToolDetailView(tool: tool, model: toolbox)
        } else if case .missing = model.selection {
            MissingApplicationsView(model: model)
        } else if let group = model.selectedGroup {
            groupDetail(for: group)
        } else {
            ProgressView("正在读取应用列表…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func groupDetail(for group: AppBoxCore.Group) -> some View {
        // 上下两条控制条改成玻璃之后，网格要真的从它们底下滚过去：
        // 玻璃背后有内容才有折射与层次，否则只是两块灰板。
        // `safeAreaInset` 让内容铺满整块区域、条子浮在上面——功能与原来一致。
        GlassGroup(spacing: 12) {
            groupContent(for: group)
                .safeAreaInset(edge: .top, spacing: 0) { detailHeader(for: group) }
                .safeAreaInset(edge: .bottom, spacing: 0) { detailFooter }
        }
    }

    @ViewBuilder
    private func groupContent(for group: AppBoxCore.Group) -> some View {
        if model.applications.isEmpty {
            emptyGroupHint(for: group)
        } else if model.filteredApplications.isEmpty {
            noMatchHint
        } else {
            applicationGrid
        }
    }

    private func detailHeader(for group: AppBoxCore.Group) -> some View {
        HStack(spacing: 8) {
            Image(systemName: group.isUngrouped ? "tray" : "folder")
                .foregroundStyle(.secondary)
            Text(group.name).font(.headline)
            Spacer(minLength: 12)
            Picker("搜索范围", selection: $model.searchScope) {
                Text("本组").tag(SearchScope.group)
                Text("全部").tag(SearchScope.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            searchField
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // 详情区顶栏：玻璃浮在网格之上，网格从它底下滚过去（见 groupDetail）。
        .glassSurface(.floating, in: .rect(cornerRadius: 16), fallback: .bar)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// 组内/全组即时过滤：输入即筛，命中规则与覆盖层搜索同一套（含拼音）。
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(model.searchScope == .all ? "搜索全部应用" : "搜索本组", text: $model.query)
                .textFieldStyle(.plain)
                .font(.callout)
                .frame(width: 160)
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                // 已在玻璃输入框上，不再铺玻璃；给一点按压反馈就够。
                .buttonStyle(GlassPressButtonStyle(scale: 0.9))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        // 这里刻意不铺玻璃：它整个嵌在玻璃顶栏里，两层玻璃会融成一块，
        // 输入框就没有边界了。给它一口「井」——浅底 + 细描边，功能一眼可辨。
        .background(.background.opacity(0.55), in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
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
        // 网格滚到上下两条玻璃底下时，边缘柔化而不是硬切（macOS 26+）。
        .glassScrollEdge([.top, .bottom])
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
            isSelected: model.selectedApplicationID == entry.bundleIdentifier,
            groupName: shownGroupName(for: entry)
        ) {
            model.selectedApplicationID = entry.bundleIdentifier
        }
    }

    /// 全组搜索时给外来应用标一下归属；本来就属于当前分组的不标，不制造噪音。
    private func shownGroupName(for entry: ApplicationEntry) -> String? {
        guard model.searchScope == .all else { return nil }
        let name = model.groupName(ofApplication: entry.bundleIdentifier)
        return name == nil || name == model.selectedGroup?.name ? nil : name
    }

    /// 状态行：计数与隐藏数在过滤时同时说「命中几 / 共几」，不误报总数。
    private var detailFooter: some View {
        HStack(spacing: 8) {
            // 压在玻璃状态条上的字各抬一级：三级 / 四级灰在玻璃上没有余量。
            Text(countSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("拖动调整顺序；拖到左侧分组则移入。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // 底部状态条与顶栏同一套：玻璃浮在网格之上，网格从底下滚过。
        .glassSurface(.floating, in: .rect(cornerRadius: 16), fallback: .bar)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var countSummary: String {
        let hidden = model.applications.filter(\.isHidden).count
        let total = model.applications.count
        let shown = model.filteredApplications.count
        let allTotal = model.allApplications.count
        let searching = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
        let base: String
        switch (model.searchScope, searching) {
        case (.group, false): base = "\(total) 个应用"
        case (.group, true): base = "命中 \(shown) / 共 \(total)"
        case (.all, false): base = "全部 \(allTotal) 个应用"
        case (.all, true): base = "全部命中 \(shown) / 共 \(allTotal)"
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

/// 侧栏分区标题。
///
/// 折叠状态下用户点标题会展开或收起，因此标题区域本身不能是按钮
/// （按钮会吃掉点击、把「点标题折叠」这件事抢走）。
private struct SidebarSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
    }
}

private struct MissingGroupRow: View {    let count: Int

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
    /// 「减弱动态效果」：瓦片不做浮起过渡。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let entry: ApplicationEntry
    let side: CGFloat
    let isSelected: Bool
    /// 全组搜索时标的归属分组；nil 表示不需要标。
    var groupName: String? = nil
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 6) {
            iconContainer
            Text(entry.displayName)
                .font(.caption)
                .lineLimit(1)
                .frame(width: side + 16)
            if let groupName {
                Text(groupName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(width: side + 16)
            }
        }
        .opacity(entry.isHidden ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.displayName)
        .accessibilityValue(accessibilityState)
    }

    private var iconContainer: some View {
        iconPlate
            // 底板单独放在背景层里切换：图标本身不参与条件分支，
            // 悬停时不会整个重新淡入。
            .background { plate }
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
            .scaleEffect(isHovering ? 1.03 : 1)
            .animation(reduceMotion ? nil : GlassMotion.quick, value: isHovering)
            .onHover { isHovering = $0 }
            .onTapGesture(perform: onSelect)
    }

    /// 瓦片的底板。与覆盖层同一套规矩：静止的瓦片只是一层浅色托底，
    /// 指针进来或选中才浮起玻璃。一屏几十个瓦片人人一块玻璃，只会糊成一片。
    @ViewBuilder
    private var plate: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if isHovering || isSelected {
            Color.clear.glassSurface(.interactive, in: shape, fallback: .regularMaterial)
        } else {
            shape.fill(.background.opacity(0.55))
        }
    }

    private var iconPlate: some View {
        Image(nsImage: iconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: side * 2 / 3, height: side * 2 / 3)
            .frame(width: side, height: side)
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
                    .glassActionButton()
                Button("确定", action: commit)
                    .keyboardShortcut(.defaultAction)
                    // 主操作给系统突出玻璃，副操作给普通玻璃（旧系统回退成 bordered）。
                    .glassActionButton(prominent: true)
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
