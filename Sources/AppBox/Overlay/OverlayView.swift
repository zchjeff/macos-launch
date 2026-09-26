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
                GroupGridView(group: group, onLaunch: onLaunch, onTapBlank: tapBlank)
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
        ScrollView {
            LazyVGrid(columns: overlayColumns, spacing: 28) {
                ForEach(snapshot.topLevelTiles) { tile in
                    switch tile {
                    case .application(let entry):
                        ApplicationTile(entry: entry) { onLaunch(entry) }
                    case .folder(let folder):
                        FolderTileView(tile: folder) { model.open(groupID: folder.id) }
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 72)
        }
    }

    /// 点空白：在子网格里先回顶层，在顶层才收起覆盖层。
    private func tapBlank() {
        if !model.back() {
            onDismiss()
        }
    }
}

/// 展开后的分组：标题 + 组内应用的全屏网格。空分组给一句空态提示。
private struct GroupGridView: View {
    let group: GroupSnapshot
    let onLaunch: (ApplicationEntry) -> Void
    let onTapBlank: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture(perform: onTapBlank)

            VStack(spacing: 28) {
                Text(group.group.name)
                    .font(.largeTitle.weight(.semibold))
                if group.visibleApplications.isEmpty {
                    Spacer()
                    emptyHint
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: overlayColumns, spacing: 28) {
                            ForEach(group.visibleApplications) { entry in
                                ApplicationTile(entry: entry) { onLaunch(entry) }
                            }
                        }
                        .padding(.horizontal, 60)
                        .padding(.vertical, 24)
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

/// 单个应用：图标加名字，单击启动并收起。
private struct ApplicationTile: View {
    let entry: ApplicationEntry
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.background.opacity(isHovering ? 0.8 : 0.55))
                    .frame(width: 96, height: 96)
                    .overlay {
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
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.background.opacity(isHovering ? 0.8 : 0.55))
                    .frame(width: 96, height: 96)
                    .overlay {
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
    count: 7
)
