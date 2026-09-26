import Foundation

/// 屏幕坐标系里的一个点。与 AppKit 一致：原点在**主屏左下角**，y 轴向上。
///
/// 刻意不依赖 AppKit，让屏幕判定逻辑可以在没有 UI 运行时的环境下测试。
public struct Point: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct Size: Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct Rect: Equatable, Sendable {
    public let origin: Point
    public let size: Size

    public init(origin: Point, size: Size) {
        self.origin = origin
        self.size = size
    }

    public var minX: Double { origin.x }
    public var maxX: Double { origin.x + size.width }
    public var minY: Double { origin.y }
    public var maxY: Double { origin.y + size.height }

    /// 使用半开区间 `[minX, maxX) × [minY, maxY)`。
    ///
    /// 相邻两块屏幕共享一条边，半开区间保证共享边上的点只归属其中一块（右侧/上方那块），
    /// 不会出现两块屏同时命中。
    public func contains(_ point: Point) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    /// 点到矩形的最短距离。点在矩形内时为 0。
    public func distance(to point: Point) -> Double {
        let dx = max(minX - point.x, 0, point.x - maxX)
        let dy = max(minY - point.y, 0, point.y - maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// 一块屏幕的几何信息。`identifier` 由调用方从 AppKit 侧填入。
public struct ScreenGeometry: Equatable, Sendable {
    public let identifier: String
    public let frame: Rect

    public init(identifier: String, frame: Rect) {
        self.identifier = identifier
        self.frame = frame
    }
}

public enum ScreenSelector {
    /// 返回包含该点的屏幕下标。
    ///
    /// 点不落在任何屏幕内时（多屏尺寸不一致时可能存在这种空隙），返回距离最近的屏幕，
    /// 而不是返回 nil——覆盖层必须显示在**某块**屏幕上，没有"不显示"这个选项。
    /// 屏幕列表为空时返回 nil。
    public static func indexOfScreen(containing point: Point, in screens: [ScreenGeometry]) -> Int? {
        if let index = screens.firstIndex(where: { $0.frame.contains(point) }) {
            return index
        }
        guard !screens.isEmpty else { return nil }

        var bestIndex = 0
        var bestDistance = screens[0].frame.distance(to: point)
        for (index, screen) in screens.enumerated().dropFirst() {
            let distance = screen.frame.distance(to: point)
            if distance < bestDistance {
                bestIndex = index
                bestDistance = distance
            }
        }
        return bestIndex
    }
}
