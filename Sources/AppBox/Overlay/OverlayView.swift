import SwiftUI

/// 002 的占位网格：20 个硬编码假应用，用来验证窗口层级、多屏判定、排版与 Esc 退出。
/// 004 会用真实扫描结果替换掉它。
struct OverlayView: View {
    let onDismiss: () -> Void

    private let columnCount = 7
    private let tiles = PlaceholderTile.samples

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 28),
                        count: columnCount
                    ),
                    spacing: 28
                ) {
                    ForEach(tiles) { tile in
                        TileView(tile: tile)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 72)
            }
        }
    }
}

private struct TileView: View {
    let tile: PlaceholderTile

    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.background.opacity(0.55))
                .frame(width: 96, height: 96)
                .overlay {
                    Image(systemName: tile.symbol)
                        .font(.system(size: 44))
                        .foregroundStyle(.primary)
                }
            Text(tile.name)
                .font(.caption)
                .lineLimit(1)
                .frame(width: 100)
        }
    }
}

struct PlaceholderTile: Identifiable {
    let id: Int
    let name: String
    let symbol: String

    static let samples: [PlaceholderTile] = [
        PlaceholderTile(id: 0, name: "访达", symbol: "face.smiling"),
        PlaceholderTile(id: 1, name: "日历", symbol: "calendar"),
        PlaceholderTile(id: 2, name: "邮件", symbol: "envelope"),
        PlaceholderTile(id: 3, name: "备忘录", symbol: "note.text"),
        PlaceholderTile(id: 4, name: "提醒事项", symbol: "checklist"),
        PlaceholderTile(id: 5, name: "地图", symbol: "map"),
        PlaceholderTile(id: 6, name: "照片", symbol: "photo"),
        PlaceholderTile(id: 7, name: "音乐", symbol: "music.note"),
        PlaceholderTile(id: 8, name: "播客", symbol: "mic"),
        PlaceholderTile(id: 9, name: "终端", symbol: "terminal"),
        PlaceholderTile(id: 10, name: "活动监视器", symbol: "gauge"),
        PlaceholderTile(id: 11, name: "磁盘工具", symbol: "externaldrive"),
        PlaceholderTile(id: 12, name: "截图", symbol: "camera.viewfinder"),
        PlaceholderTile(id: 13, name: "系统设置", symbol: "gearshape"),
        PlaceholderTile(id: 14, name: "计算器", symbol: "plusminus"),
        PlaceholderTile(id: 15, name: "时钟", symbol: "clock"),
        PlaceholderTile(id: 16, name: "预览", symbol: "doc.text.magnifyingglass"),
        PlaceholderTile(id: 17, name: "词典", symbol: "character.book.closed"),
        PlaceholderTile(id: 18, name: "字体册", symbol: "textformat"),
        PlaceholderTile(id: 19, name: "钥匙串访问", symbol: "key"),
    ]
}
