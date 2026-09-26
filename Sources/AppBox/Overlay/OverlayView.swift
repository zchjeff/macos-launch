import AppBoxCore
import SwiftUI

/// 覆盖层：顶层是「单图标 + 分组方块」的平铺网格，点方块展开该组的子网格；
/// 顶部搜索框始终在，输入即筛选，结果平铺不分组的浮层盖在最上面。
///
/// 用的是「可见」那一份投影：被隐藏的应用不出现在覆盖层的任何位置。
struct OverlayView: View {
    let snapshot: LibrarySnapshot
    let model: OverlayModel
    let onLaunch: (ApplicationEntry) -> Void
    let onDismiss: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            background

            // 顶层网格一直挂着，子网格是盖在它上面的一层：返回顶层时滚动位置与
            // 悬停状态都还在原处，不需要另存一份再恢复。
            topGrid

            if case .group(let id) = model.level,
               let group = snapshot.groups.first(where: { $0.group.id == id }) {
                GroupGridView(group: group, model: model, onLaunch: onLaunch, onTapBlank: tapBlank)
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
        .onChange(of: model.focusRequest) { _, _ in searchFocused = true }
        .onAppear { searchFocused = true }
    }

    private var background: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .ignoresSafeArea()
            .onTapGesture(perform: tapBlank)
    }

    /// 顶部的搜索框。始终挂在最上层：在子网格里也能直接搜全库。
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索应用", text: queryBinding)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .frame(width: 260)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Capsule().fill(.background.opacity(0.8)))
        .overlay(Capsule().strokeBorder(.quaternary))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 14)
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
                        TileView(
                            tile: tile,
                            isHighlighted: model.level == .top && !model.isSearching
                                && index == model.selection,
                            onLaunch: onLaunch,
                            onOpenFolder: { model.open(groupID: $0) }
                        )
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 72)
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
    let onLaunch: (ApplicationEntry) -> Void
    let onTapBlank: () -> Void

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
                                    TileView(
                                        tile: tile,
                                        isHighlighted: !model.isSearching && index == model.selection,
                                        onLaunch: onLaunch,
                                        onOpenFolder: { _ in }
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
            .padding(.top, 64)
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
private struct TileView: View {
    let tile: OverlayTile
    let isHighlighted: Bool
    let onLaunch: (ApplicationEntry) -> Void
    let onOpenFolder: (String) -> Void

    var body: some View {
        switch tile {
        case .application(let entry):
            ApplicationTile(entry: entry, isHighlighted: isHighlighted) { onLaunch(entry) }
        case .folder(let folder):
            FolderTileView(tile: folder, isHighlighted: isHighlighted) { onOpenFolder(folder.id) }
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
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                TileSurface(isActive: isHovering || isHighlighted, isHighlighted: isHighlighted) {
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
    }
}

/// 分组方块：组内前 9 个应用的缩略图标按实际数量铺在方块里。
private struct FolderTileView: View {
    let tile: FolderTile
    let isHighlighted: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                TileSurface(isActive: isHovering || isHighlighted, isHighlighted: isHighlighted) {
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
