import AppBoxCore
import SwiftUI

/// 覆盖层：顶层是「单图标 + 分组方块」的平铺网格，点方块展开该组的子网格。
///
/// 用的是「可见」那一份投影：被隐藏的应用不出现在覆盖层的任何位置。
struct OverlayView: View {
    let snapshot: LibrarySnapshot
    let model: OverlayModel
    let onLaunch: (ApplicationEntry) -> Void
    let onDismiss: () -> Void

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
        }
        // 展开与返回都由 level 驱动：Esc、点空白、点方块三条路走的是同一个状态。
        .animation(.easeOut(duration: 0.16), value: model.level)
    }

    private var background: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .ignoresSafeArea()
            .onTapGesture(perform: tapBlank)
    }

    private var topGrid: some View {
        let tiles = snapshot.topLevelTiles
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: overlayColumns, spacing: 28) {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                        TileView(
                            tile: tile,
                            isHighlighted: model.level == .top && index == model.selection,
                            onLaunch: onLaunch,
                            onOpenFolder: { model.open(groupID: $0) }
                        )
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 72)
            }
            // 高亮换了行才需要把它带进画面（左右挪动不换行，视图就不动）。
            // 子网格开着的时候顶层网格不该跟着动——那会儿高亮走的是子网格那一份。
            .onChange(of: model.selection) { old, new in
                guard model.level == .top,
                      old / OverlayGrid.columns != new / OverlayGrid.columns else { return }
                scrollToSelection(proxy, in: tiles, selection: new)
            }
        }
    }

    /// 点空白：在子网格里先回顶层，在顶层才收起覆盖层。
    private func tapBlank() {
        if !model.back() {
            onDismiss()
        }
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
                                        isHighlighted: index == model.selection,
                                        onLaunch: onLaunch,
                                        onOpenFolder: { _ in }
                                    )
                                }
                            }
                            .padding(.horizontal, 60)
                            .padding(.vertical, 24)
                        }
                        .onChange(of: model.selection) { old, new in
                            guard old / OverlayGrid.columns != new / OverlayGrid.columns else { return }
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
