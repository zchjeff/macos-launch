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
    /// 顶层格子的位置与当前被瞄准的格子。子网格那两份是它自己的（见 `GroupGridView`）——
    /// 两层可能同时开着，落点状态也必须是两份。
    @State private var topFrames: [Int: Rect] = [:]
    @State private var topDropTarget: Int?

    var body: some View {
        ZStack {
            background

            // 顶层网格一直挂着，子网格是盖在它上面的一层：返回顶层时滚动位置与
            // 悬停状态都还在原处，不需要另存一份再恢复。
            topGrid

            if case .group(let id) = model.level,
               let group = snapshot.groups.first(where: { $0.group.id == id }) {
                GroupGridView(
                    group: group,
                    model: model,
                    topInset: topInset,
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
        // 展开与返回都由 level 驱动：Esc、点空白、点方块三条路走的是同一个状态。
        .animation(.easeOut(duration: 0.16), value: model.level)
        .animation(.easeOut(duration: 0.12), value: model.isSearching)
        // 输入框自己改的查询由这里回流到模型；控制器塞进来的字符也会经过它。
        // `updateSearch` 是幂等的，两边同时触发不会把状态搅乱。
        .onChange(of: model.query) { _, _ in model.updateSearch(in: snapshot) }
        // 控制器说该有焦点了（唤起时、或焦点不在输入框却敲了字）。
        // TEMP（012 Esc 定位实验，测完恢复）：停掉自动聚焦，看拖拽中 Esc 能不能恢复取消。
        // .onChange(of: model.focusRequest) { _, _ in searchFocused = true }
        // .onAppear { searchFocused = true }
    }

    private var background: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .ignoresSafeArea()
            .onTapGesture(perform: tapBlank)
    }

    /// 顶部的搜索框。始终挂在最上层：在子网格里也能直接搜全库。
    ///
    /// 聚焦时描边换成强调色并带一圈柔光——毛玻璃底上单靠 1pt 灰线分不清
    /// 「能输入」和「正在输入」。
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
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Capsule().fill(.background.opacity(0.8)))
        .overlay {
            // 未聚焦沿用原来的 .quaternary 细描边；聚焦换强调色。
            if searchFocused {
                Capsule().strokeBorder(Color.accentColor, lineWidth: 1.5)
            } else {
                Capsule().strokeBorder(.quaternary)
            }
        }
        .shadow(color: searchFocused ? Color.accentColor.opacity(0.25) : .clear, radius: 6)
        .animation(.easeOut(duration: 0.15), value: searchFocused)
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
                    .onChange(of: model.selection) { old, new in
                        guard old / OverlayGrid.columns != new / OverlayGrid.columns else { return }
                        scrollToSelection(proxy, in: tiles, selection: new)
                    }
                }
            }
        }
        .transition(.opacity)
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("没有匹配的应用")
                .foregroundStyle(.secondary)
            Text("换个关键词试试；拼音首字母也行，比如 wx 找微信。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// 展开后的分组：标题 + 组内应用的全屏网格。空分组给一句空态提示。
private struct GroupGridView: View {
    let group: GroupSnapshot
    let model: OverlayModel
    /// 刘海屏要让出的顶部高度，与搜索框同一份数字。
    var topInset: CGFloat = 0
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
                Text(group.group.name)
                    .font(.largeTitle.weight(.semibold))
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
                .foregroundStyle(.tertiary)
        }
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
                isDropTargeted: isDropTargeted
            ) { onOpenFolder(folder.id) }
        }
    }
}

/// 格子的底：悬停或键盘高亮时托底变亮，键盘高亮再套一圈系统的焦点环。
///
/// 悬停与高亮是两套东西——鼠标停上去不改键盘高亮的位置，两者可以同时落在
/// 不同的格子上，所以外观也分成两级：发亮（任一）与焦点环（只有键盘高亮）。
///
/// 焦点环用强调色而不是白色：图标底下就是浅色的毛玻璃，一圈白边根本看不出来。
private struct TileSurface<Content: View>: View {
    let isActive: Bool
    let isHighlighted: Bool
    let content: Content

    init(isActive: Bool, isHighlighted: Bool, @ViewBuilder content: () -> Content) {
        self.isActive = isActive
        self.isHighlighted = isHighlighted
        self.content = content()
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.background.opacity(isActive ? 0.9 : 0.55))
            .frame(width: 96, height: 96)
            .overlay { content }
            .overlay {
                // 比图标大一圈、留一点缝，像系统的焦点环那样「套在外面」。
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: 106, height: 106)
                    .opacity(isHighlighted ? 1 : 0)
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
        .buttonStyle(.plain)
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
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                TileSurface(
                    isActive: isHovering || isHighlighted || isDropTargeted,
                    isHighlighted: isHighlighted || isDropTargeted
                ) {
                    thumbnails
                }
                Text(tile.name)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(width: 100)
            }
        }
        .buttonStyle(.plain)
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
