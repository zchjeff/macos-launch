import AppBoxCore
import SwiftUI

/// 覆盖层：顶层是「单图标 + 分组方块」的平铺网格，点方块展开该组的子网格；
/// 顶部搜索框始终在，输入即筛选，结果平铺不分组的浮层盖在最上面。
///
/// 用的是「可见」那一份投影：被隐藏的应用不出现在覆盖层的任何位置。
struct OverlayView: View {
    let snapshot: LibrarySnapshot
    let model: OverlayModel
    /// 顶部要让出的高度：有刘海的屏是刘海深度，其余屏幕为 0。
    /// 搜索框贴着顶部摆，不让开就会被刘海压住。
    var topInset: CGFloat = 0
    let onLaunch: (ApplicationEntry) -> Void
    let onDismiss: () -> Void
    /// 一次拖拽落地：哪一层、拖的是什么、容器坐标里的落点、那一层的格子位置。
    /// 视图只管把这几样说清楚；判定与落盘都在控制器那边，与控制台走同一套领域动作。
    let onDrop: (OverlayModel.Level, OverlayDragItem, Point, [Int: Rect]) -> Bool

    @FocusState private var searchFocused: Bool
    /// 玻璃形变的命名空间：分组方块被点开时，它的那块玻璃要「飞」成子网格的标题。
    /// 两边挂同一个 ID（`overlay-group-<分组 id>`），形变才连得上。
    @Namespace private var glassNamespace
    /// 「减弱动态效果」：玻璃的形变与浮起一律退化成直接切换。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 顶层格子的位置与当前被瞄准的格子。子网格那两份是它自己的（见 `GroupGridView`）——
    /// 两层可能同时开着，落点状态也必须是两份。
    @State private var topFrames: [Int: Rect] = [:]
    @State private var topDropTarget: Int?

    var body: some View {
        ZStack {
            // 整屏遮罩不进玻璃容器：它不是玻璃，而且要照旧 ignoresSafeArea 铺满
            // （刘海屏的顶部也得盖住），不该被玻璃容器的合成范围牵着走。
            background

            // 这一屏所有玻璃收在同一个容器里：间距统一（相邻玻璃才谈得上融合），
            // 也只有在同一个容器里，同一个 ID 的两块玻璃才会形变而不是各闪各的。
            // 容器内仍显式用 ZStack 叠层：玻璃容器的职责是合成玻璃，不是排版。
            // macOS 26 以下 GlassGroup 直接透传内容，布局一模一样。
            GlassGroup(spacing: 20) {
                ZStack {
                    // 顶层网格一直挂着，子网格是盖在它上面的一层：返回顶层时滚动位置与
                    // 悬停状态都还在原处，不需要另存一份再恢复。
                    topGrid

                    if case .group(let id) = model.level,
                       let group = snapshot.groups.first(where: { $0.group.id == id }) {
                        GroupGridView(
                            group: group,
                            model: model,
                            topInset: topInset,
                            namespace: glassNamespace,
                            onLaunch: onLaunch,
                            onTapBlank: tapBlank,
                            onDrop: { item, point, frames in onDrop(.group(id), item, point, frames) }
                        )
                    }

                    if model.isSearching {
                        SearchResultsView(
                            results: model.searchResults,
                            model: model,
                            onLaunch: onLaunch,
                            onTapBlank: clearSearch
                        )
                    }

                    searchBar
                }
            }
        }
        // 展开与返回都由 level 驱动：Esc、点空白、点方块三条路走的是同一个状态。
        // 换成系统风格的弹簧：子网格是「长出来」的，子网格标题接住方块飞过来的玻璃。
        // 开了「减弱动态效果」就不做过渡：状态照变，只是不再飞。
        .animation(reduceMotion ? nil : GlassMotion.standard, value: model.level)
        .animation(reduceMotion ? nil : GlassMotion.quick, value: model.isSearching)
        // 输入框自己改的查询由这里回流到模型；控制器塞进来的字符也会经过它。
        // `updateSearch` 是幂等的，两边同时触发不会把状态搅乱。
        .onChange(of: model.query) { _, _ in model.updateSearch(in: snapshot) }
        // 控制器说该有焦点了（唤起时、或焦点不在输入框却敲了字）。
        // TEMP（012 Esc 定位实验，测完恢复）：停掉自动聚焦，看拖拽中 Esc 能不能恢复取消。
        // .onChange(of: model.focusRequest) { _, _ in searchFocused = true }
        // .onAppear { searchFocused = true }
    }

    /// 覆盖层的底：整屏的遮罩，故意不铺玻璃。
    ///
    /// Liquid Glass 是给「浮在内容之上」的东西用的。整屏铺一层玻璃会把底下的
    /// 壁纸与窗口全抹平，玻璃之间也没了层次——这一层是衬托，材质就够了。
    /// 上面那些搜索框、格子、标题才是真正的玻璃。
    private var background: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .ignoresSafeArea()
            .onTapGesture(perform: tapBlank)
    }

    /// 顶部的搜索框。始终挂在最上层：在子网格里也能直接搜全库。
    ///
    /// 聚焦时玻璃带一点强调色着色，再补一圈描边——只靠玻璃自身的明暗变化，
    /// 分不清「能输入」和「正在输入」，提高对比度设置下更是看不出来。
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索应用", text: queryBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                .frame(width: 320)
            if !model.query.isEmpty {
                Button {
                    clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                // 清空键本身不再铺玻璃——它已经在玻璃搜索框上，两层玻璃只会发浑；
                // 但按压要给一点轻快反馈。
                .buttonStyle(GlassPressButtonStyle(scale: 0.9))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        // 交互玻璃：指针靠近、按下时系统自己给高光，不需要手写模糊。
        .glassSurface(
            .interactive,
            in: Capsule(),
            tint: searchFocused ? Color.accentColor.opacity(0.3) : nil,
            // 覆盖层的遮罩本身就是材质，旧系统上玻璃再退回 ultraThinMaterial
            // 会和遮罩糊成一片、胶囊边界消失——原来这里是接近不透明的底色。
            fallback: .bar
        )
        .glassIdentity("overlay-search-bar", in: glassNamespace)
        .overlay {
            // 未聚焦沿用原来的 .quaternary 细描边；聚焦换强调色。
            if searchFocused {
                Capsule().strokeBorder(Color.accentColor, lineWidth: 1.5)
            } else {
                Capsule().strokeBorder(.quaternary)
            }
        }
        .shadow(color: searchFocused ? Color.accentColor.opacity(0.25) : .clear, radius: 6)
        .animation(reduceMotion ? nil : GlassMotion.quick, value: searchFocused)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 14 + topInset)
    }

    /// 输入框把编辑后的全文交回模型：写入、粘贴、输入法改字都从这一条路走。
    private var queryBinding: Binding<String> {
        Binding(get: { model.query }, set: { model.replaceQuery($0) })
    }

    private var topGrid: some View {
        let tiles = snapshot.topLevelTiles
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: overlayColumns, spacing: 28) {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                        DroppableTile(
                            tile: tile,
                            index: index,
                            isHighlighted: model.level == .top && !model.isSearching
                                && index == model.selection,
                            isDropTargeted: topDropTarget == index,
                            space: OverlayDropSpaces.top,
                            // 只有在顶层才把玻璃身份交出去：子网格开着时方块还挂在下面
                            // （悬停未退），身份要是一直挂着就会和子网格标题撞同一个 ID。
                            namespace: model.level == .top ? glassNamespace : nil,
                            onLaunch: onLaunch,
                            onOpenFolder: { model.open(groupID: $0) },
                            onDropApplication: { bundleIdentifier, location, index in
                                guard let point = containerPoint(
                                    location: location, tileIndex: index, frames: topFrames
                                ) else { return false }
                                return onDrop(
                                    .top,
                                    .application(bundleIdentifier: bundleIdentifier),
                                    point,
                                    topFrames
                                )
                            },
                            onTargetedChange: { targeted in
                                topDropTarget = dropTargetUpdate(
                                    current: topDropTarget, targeted: targeted, index: index
                                )
                            }
                        )
                    }
                }
                .padding(.horizontal, 60)
                .padding(.top, 72 + topInset)
                .padding(.bottom, 72)
            }
            // 格子会滚到浮在顶上的搜索框底下，边缘柔化一点，别硬切。
            .glassScrollEdge(.top)
            // 格子位置与落点必须是同一套数字：量法（`.named`）与落点（dropDestination）
            // 都以这一层为原点。
            .coordinateSpace(name: OverlayDropSpaces.top)
            .onPreferenceChange(TileFramesKey.self) { topFrames = $0 }
            // 拖分组方块进顶层：落在哪个格子边上就在哪儿插队。
            // 这一层只登记方块载荷——应用落在顶层空白是拒绝（未分类已经在顶层了），
            // 连登记都不登记：系统直接不给这个手势，比先接住再拒绝诚实。
            .guardedDropDestination(for: GroupDragPayload.self) { payload, location in
                onDrop(
                    .top,
                    .folder(groupID: payload.groupID),
                    Point(x: location.x, y: location.y),
                    topFrames
                )
            }
            // 高亮换了行才需要把它带进画面（左右挪动不换行，视图就不动）。
            // 子网格或搜索盖着的时候顶层网格不该跟着动——那会儿高亮走的是另一份。
            .onChange(of: model.selection) { old, new in
                guard model.level == .top, !model.isSearching,
                      old / OverlayGrid.columns != new / OverlayGrid.columns else { return }
                scrollToSelection(proxy, in: tiles, selection: new)
            }
        }
    }

    /// 点空白：搜索中先清查询，子网格里先回顶层，在顶层才收起覆盖层。
    private func tapBlank() {
        if model.isSearching {
            clearSearch()
        } else if !model.back() {
            onDismiss()
        }
    }

    private func clearSearch() {
        model.clearSearch()
        model.updateSearch(in: snapshot)
    }
}

/// 把高亮项滚进画面。
///
/// 锚点用居中：换行时视角跟着走一格，高亮始终停在中间附近，像编辑器的光标。
private func scrollToSelection(_ proxy: ScrollViewProxy, in tiles: [OverlayTile], selection: Int) {
    guard tiles.indices.contains(selection) else { return }
    withAnimation(.easeOut(duration: 0.12)) {
        proxy.scrollTo(tiles[selection].id, anchor: .center)
    }
}

/// 搜索结果：平铺、不分组、跨全部应用的一层浮层。
private struct SearchResultsView: View {
    let results: [ApplicationEntry]
    let model: OverlayModel
    let onLaunch: (ApplicationEntry) -> Void
    let onTapBlank: () -> Void

    var body: some View {
        let tiles = results.map(OverlayTile.application)
        return ZStack {
            // 结果层是盖在顶层网格上的浮层，背后有内容——这里材质仍是衬托，
            // 真正浮起来的是下面那张空态卡片和滚动区里的格子玻璃。
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture(perform: onTapBlank)

            if tiles.isEmpty {
                Spacer()
                emptyHint
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: overlayColumns, spacing: 28) {
                            ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                                TileView(
                                    tile: tile,
                                    isHighlighted: index == model.selection,
                                    isDropTargeted: false,
                                    onLaunch: onLaunch,
                                    onOpenFolder: { _ in }
                                )
                            }
                        }
                        .padding(.horizontal, 60)
                        .padding(.vertical, 72)
                    }
                    // 与顶层网格同一套：滚到搜索框底下时边缘柔化。
                    .glassScrollEdge(.top)
                    .onChange(of: model.selection) { old, new in
                        guard old / OverlayGrid.columns != new / OverlayGrid.columns else { return }
                        scrollToSelection(proxy, in: tiles, selection: new)
                    }
                }
            }
        }
        .transition(.opacity)
    }

    /// 空结果：一张浮起来的玻璃卡片。背后是覆盖层的遮罩，卡片才立得住。
    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("没有匹配的应用")
                .foregroundStyle(.secondary)
            // 压在玻璃上的说明文字抬到 .secondary：玻璃本身有底色，
            // 三级灰在「提高对比度」下会糊掉。
            Text("换个关键词试试；拼音首字母也行，比如 wx 找微信。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        // 卡片在旧系统上用 regularMaterial：比 ultraThinMaterial 实一点，卡片才立得住。
        .glassSurface(.floating, in: .rect(cornerRadius: 20), fallback: .regularMaterial)
    }
}

/// 展开后的分组：标题 + 组内应用的全屏网格。空分组给一句空态提示。
private struct GroupGridView: View {
    let group: GroupSnapshot
    let model: OverlayModel
    /// 刘海屏要让出的顶部高度，与搜索框同一份数字。
    var topInset: CGFloat = 0
    /// 玻璃形变的命名空间：标题要接住被点开的方块飞过来的那块玻璃，得跟覆盖层共用一份。
    let namespace: Namespace.ID
    let onLaunch: (ApplicationEntry) -> Void
    let onTapBlank: () -> Void
    /// 这一层上的一次拖拽落地（容器坐标 + 这一层的格子位置）。
    let onDrop: (OverlayDragItem, Point, [Int: Rect]) -> Bool

    /// 这一层的格子位置与被瞄准的格子。跟着视图一起生灭：退了子网格就作废，
    /// 下一层（或另一个分组）不会拿到上一层的数字。
    @State private var frames: [Int: Rect] = [:]
    @State private var dropTarget: Int?

    var body: some View {
        let tiles = group.visibleApplications.map(OverlayTile.application)
        return ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture(perform: onTapBlank)

            VStack(spacing: 28) {
                // 块标题做成一块浮起来的玻璃胶囊：点开分组时，方块那块玻璃顺着
                // 同一个 ID 形变到这里，用户看到的是「东西飞上来了」而不是「换了屏」。
                Text(group.group.name)
                    .font(.largeTitle.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .glassSurface(.floating, in: Capsule(), fallback: .regularMaterial)
                    .glassIdentity("overlay-group-\(group.group.id)", in: namespace)
                if tiles.isEmpty {
                    Spacer()
                    emptyHint
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: overlayColumns, spacing: 28) {
                                ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                                    DroppableTile(
                                        tile: tile,
                                        index: index,
                                        isHighlighted: !model.isSearching && index == model.selection,
                                        isDropTargeted: dropTarget == index,
                                        space: OverlayDropSpaces.group,
                                        onLaunch: onLaunch,
                                        onOpenFolder: { _ in },
                                        onDropApplication: { bundleIdentifier, location, index in
                                            guard let point = containerPoint(
                                                location: location, tileIndex: index, frames: frames
                                            ) else { return false }
                                            return onDrop(
                                                .application(bundleIdentifier: bundleIdentifier),
                                                point,
                                                frames
                                            )
                                        },
                                        onTargetedChange: { targeted in
                                            dropTarget = dropTargetUpdate(
                                                current: dropTarget, targeted: targeted, index: index
                                            )
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 60)
                            .padding(.vertical, 24)
                        }
                        .glassScrollEdge(.top)
                        .onChange(of: model.selection) { old, new in
                            guard !model.isSearching,
                                  old / OverlayGrid.columns != new / OverlayGrid.columns else { return }
                            scrollToSelection(proxy, in: tiles, selection: new)
                        }
                    }
                }
            }
            .padding(.top, 100 + topInset)
        }
        // 格子位置与落点都以这一层为原点，贴着两个网格一起量、一起收。
        .coordinateSpace(name: OverlayDropSpaces.group)
        .onPreferenceChange(TileFramesKey.self) { frames = $0 }
        // 子网格的空白接住的是应用：落在这儿 = 放回「未分类」。
        // 分组方块这一层不登记——方块只从顶层拖出、也只在顶层落地。
        .guardedDropDestination(for: ApplicationDragPayload.self) { payload, location in
            onDrop(
                .application(bundleIdentifier: payload.bundleIdentifier),
                Point(x: location.x, y: location.y),
                frames
            )
        }
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.dashed")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("这个分组还是空的")
                .foregroundStyle(.secondary)
            Text("在控制台里把应用拖进来，它们就会出现在这儿。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .glassSurface(.floating, in: .rect(cornerRadius: 20), fallback: .regularMaterial)
    }
}

/// 一个格子：单图标与方块共用同一副外壳，免得两处的高亮样子长歪。
struct TileView: View {
    let tile: OverlayTile
    let isHighlighted: Bool
    /// 正被拖拽瞄准：「松手就落在这儿」。给的是和键盘高亮同一圈环——
    /// 两者不会同时出现（拖拽时没人按键盘），共用一个环不会撞车。
    let isDropTargeted: Bool
    let onLaunch: (ApplicationEntry) -> Void
    let onOpenFolder: (String) -> Void
    /// 玻璃形变的命名空间。分组方块要用它把玻璃交棒给子网格标题；
    /// 搜索结果里的应用格子不需要，默认为空。
    var namespace: Namespace.ID? = nil

    var body: some View {
        switch tile {
        case .application(let entry):
            ApplicationTile(
                entry: entry,
                isHighlighted: isHighlighted,
                isDropTargeted: isDropTargeted
            ) { onLaunch(entry) }
        case .folder(let folder):
            FolderTileView(
                tile: folder,
                isHighlighted: isHighlighted,
                isDropTargeted: isDropTargeted,
                // 展开时按这个 ID 把玻璃交给 `GroupGridView` 的标题。
                glassID: "overlay-group-\(folder.id)",
                namespace: namespace
            ) { onOpenFolder(folder.id) }
        }
    }
}

/// 格子的底：静止时一层浅色托底，被悬停 / 键盘高亮 / 拖拽瞄准时换成一块玻璃。
///
/// 悬停与高亮是两套东西——鼠标停上去不改键盘高亮的位置，两者可以同时落在
/// 不同的格子上，所以外观也分成两级：发亮（任一）与焦点环（只有键盘高亮）。
///
/// 焦点环用强调色而不是白色：图标底下就是浅色的玻璃，一圈白边根本看不出来。
///
/// 为什么只有「活着」的格子才铺玻璃：一屏几十个格子人人一块玻璃，既没有层次
/// （玻璃叠玻璃只会浑浊），又白让 GPU 每帧重算折射。静止的格子用一层半透明
/// 底色托住图标就够了；指针一进来玻璃才浮起来——这本身就是最直接的交互反馈。
private struct TileSurface<Content: View>: View {
    let isActive: Bool
    let isHighlighted: Bool
    /// 「减弱动态效果」：底板不做淡入淡出。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 只有分组方块需要：展开时按这个 ID 把玻璃交棒给子网格标题。
    var glassID: String?
    var namespace: Namespace.ID?
    let content: Content

    init(
        isActive: Bool,
        isHighlighted: Bool,
        glassID: String? = nil,
        namespace: Namespace.ID? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.isActive = isActive
        self.isHighlighted = isHighlighted
        self.glassID = glassID
        self.namespace = namespace
        self.content = content()
    }

    var body: some View {
        content
            .frame(width: 96, height: 96)
            // 底板（玻璃或浅色）单独放在背景层里切换：图标始终是同一个视图，
            // 不会因为悬停 / 键盘移动而重新淡入——那种闪烁比玻璃本身更扎眼。
            .background { plate }
            .overlay {
                // 比图标大一圈、留一点缝，像系统的焦点环那样「套在外面」。
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: 106, height: 106)
                    .opacity(isHighlighted ? 1 : 0)
            }
            // 玻璃是浮起来 / 收回去，不是「啪」地换一张图：给状态变化配一小段弹簧。
            .animation(reduceMotion ? nil : GlassMotion.quick, value: isActive)
    }

    /// 底板：活着的格子是玻璃，静止的格子只是一层浅色。
    @ViewBuilder
    private var plate: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if isActive {
            Color.clear
                // 旧系统上没有 Liquid Glass，用 regularMaterial 接近原来那层近不透明底。
                .glassSurface(.interactive, in: shape, fallback: .regularMaterial)
                .glassIdentityIfPresent(glassID, in: namespace)
        } else {
            shape.fill(.background.opacity(0.55))
        }
    }
}

/// 单个应用：图标加名字，单击启动并收起。
private struct ApplicationTile: View {
    let entry: ApplicationEntry
    let isHighlighted: Bool
    let isDropTargeted: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                TileSurface(
                    isActive: isHovering || isHighlighted || isDropTargeted,
                    isHighlighted: isHighlighted || isDropTargeted
                ) {
                    IconImage(entry: entry)
                        .frame(width: 96, height: 96)
                }
                Text(entry.displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(width: 100)
            }
        }
        // 按压反馈用自定义样式：玻璃已经铺在格子上，再用系统玻璃按钮就是两层玻璃。
        .buttonStyle(GlassPressButtonStyle())
        .onHover { isHovering = $0 }
        .accessibilityLabel(entry.displayName)
        .accessibilityValue(entry.isHidden ? "已隐藏" : "")
    }
}

/// 分组方块：组内前 9 个应用的缩略图标按实际数量铺在方块里。
private struct FolderTileView: View {
    let tile: FolderTile
    let isHighlighted: Bool
    let isDropTargeted: Bool
    /// 展开时交给子网格标题的那块玻璃的身份。
    var glassID: String? = nil
    var namespace: Namespace.ID? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                TileSurface(
                    isActive: isHovering || isHighlighted || isDropTargeted,
                    isHighlighted: isHighlighted || isDropTargeted,
                    glassID: glassID,
                    namespace: namespace
                ) {
                    thumbnails
                }
                Text(tile.name)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(width: 100)
            }
        }
        .buttonStyle(GlassPressButtonStyle())
        .onHover { isHovering = $0 }
        .accessibilityLabel(tile.name)
        .accessibilityHint("分组，按下展开")
    }

    /// 不足 9 个时按实际数量排布，不留空占位；1 个时单个图标画大一点，
    /// 免得一个方块里飘着一个针尖大的图标。
    private var thumbnails: some View {
        let side = thumbnailSide
        return LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(side), spacing: 4), count: gridSide),
            spacing: 4
        ) {
            ForEach(tile.thumbnails) { entry in
                IconImage(entry: entry)
                    .frame(width: side, height: side)
            }
        }
    }

    /// 摆成尽量方正的格子：1 个单列、2–4 个两列、5–9 个三列。
    private var gridSide: Int {
        Int(ceil(Double(tile.thumbnails.count).squareRoot()))
    }

    private var thumbnailSide: CGFloat {
        switch gridSide {
        case 1: 56
        case 2: 40
        default: 26
        }
    }
}

/// 图标本体：有缓存就用缓存，没有就画个占位符号。
private struct IconImage: View {
    let entry: ApplicationEntry

    var body: some View {
        if let image = entry.iconCachePath.flatMap(IconImageStore.image(atPath:)) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "app.fill")
                .resizable()
                .scaledToFit()
                .padding(6)
                .foregroundStyle(.secondary)
        }
    }
}

private let overlayColumns: [GridItem] = Array(
    repeating: GridItem(.flexible(), spacing: 28),
    count: OverlayGrid.columns
)
