import AppBoxCore
import Testing

/// 两块尺寸不一致的屏幕，模拟笔记本 + 外接显示器的常见布局。
/// 主屏 1440×900 在左下，副屏 2560×1440 摆在主屏右侧且更高——两者之间存在空隙。
private let laptop = ScreenGeometry(
    identifier: "laptop",
    frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 1440, height: 900))
)
private let external = ScreenGeometry(
    identifier: "external",
    frame: Rect(origin: Point(x: 1440, y: 0), size: Size(width: 2560, height: 1440))
)
private let screens = [laptop, external]

@Test("鼠标在主屏时选中主屏")
func selectsPrimaryScreenWhenPointIsInsideIt() {
    let index = ScreenSelector.indexOfScreen(containing: Point(x: 700, y: 400), in: screens)
    #expect(index == 0)
}

@Test("鼠标在副屏时选中副屏，而不是回落到主屏")
func selectsSecondaryScreenWhenPointIsInsideIt() {
    let index = ScreenSelector.indexOfScreen(containing: Point(x: 2000, y: 1200), in: screens)
    #expect(index == 1)
}

@Test("副屏高出主屏的那块区域仍属于副屏")
func selectsSecondaryScreenAbovePrimaryHeight() {
    let index = ScreenSelector.indexOfScreen(containing: Point(x: 2000, y: 1300), in: screens)
    #expect(index == 1)
}

@Test("屏幕原点属于该屏幕")
func screenOriginBelongsToThatScreen() {
    #expect(ScreenSelector.indexOfScreen(containing: Point(x: 0, y: 0), in: screens) == 0)
    #expect(ScreenSelector.indexOfScreen(containing: Point(x: 1440, y: 0), in: screens) == 1)
}

@Test("两块屏共享边上的点只归属其中一块，不会同时命中")
func sharedEdgePointResolvesToExactlyOneScreen() {
    let matches = screens.filter { $0.frame.contains(Point(x: 1440, y: 100)) }
    #expect(matches.count == 1)
    #expect(matches.first?.identifier == "external")
}

@Test("点落在屏幕之间的空隙时，选距离最近的屏幕而非返回空")
func pointInGapFallsBackToNearestScreen() {
    // 主屏上方、副屏左侧的那块空隙：只可能出现在主屏高度之外。
    let index = ScreenSelector.indexOfScreen(containing: Point(x: 700, y: 1200), in: screens)
    #expect(index == 0)
}

@Test("屏幕列表为空时返回空")
func returnsNilWhenNoScreens() {
    #expect(ScreenSelector.indexOfScreen(containing: Point(x: 0, y: 0), in: []) == nil)
}

@Test("单屏时任何点都落在该屏上")
func singleScreenAlwaysMatches() {
    let index = ScreenSelector.indexOfScreen(containing: Point(x: -5000, y: 9999), in: [laptop])
    #expect(index == 0)
}

@Test("矩形距离计算：内部为 0，水平/垂直/斜向各取最短")
func rectDistanceIsZeroInsideAndShortestOutside() {
    let rect = Rect(origin: Point(x: 0, y: 0), size: Size(width: 100, height: 100))
    #expect(rect.distance(to: Point(x: 50, y: 50)) == 0)
    #expect(rect.distance(to: Point(x: 130, y: 50)) == 30)
    #expect(rect.distance(to: Point(x: 50, y: -40)) == 40)
    #expect(rect.distance(to: Point(x: 103, y: 104)) == 5)
}
