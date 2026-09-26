import AppBoxCore
import SwiftUI

/// 覆盖层网格：渲染 `LibrarySnapshot` 里的真实应用，单击启动并收起。
struct OverlayView: View {
    let snapshot: LibrarySnapshot
    let onLaunch: (ApplicationEntry) -> Void
    let onDismiss: () -> Void

    private let columnCount = 7

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
                    ForEach(snapshot.allApplications) { entry in
                        TileView(entry: entry) { onLaunch(entry) }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 72)
            }
        }
    }
}

private struct TileView: View {
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
                        icon
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

    @ViewBuilder
    private var icon: some View {
        if let image = entry.iconCachePath.flatMap(IconImageStore.image(atPath:)) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
        }
    }
}
