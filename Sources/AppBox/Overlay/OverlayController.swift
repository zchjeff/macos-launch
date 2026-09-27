import AppBoxCore
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 覆盖层的生命周期与窗口配置。
///
/// 唤起瞬间判定目标屏幕、创建窗口、抢焦点；收起时把焦点还给原来的前台应用。
///
/// 窗口只建一次、收起时 `orderOut` 而不销毁：重建一个全屏窗口连同它的
/// SwiftUI 视图树要 60ms 以上，而热键这条路径的预算是 150ms。
@MainActor
final class OverlayController {
    private let service: LibraryService
    /// 顶层 ↔ 子网格的导航状态。放在控制器里而不是视图里：视图树在快照变化时
    /// 会被整体重建，而 Esc 的判定在视图之外（键盘监听器）。
    private let model = OverlayModel()
    private var window: OverlayWindow?
    private var hostingView: NSHostingView<OverlayView>?
    /// 最近一次算出来的快照。与 `renderedSnapshot` 分开：窗口还没建的时候也得
    /// 留住它，否则首屏是一张空网格，要等扫描回来才填上。
    private var latestSnapshot: LibrarySnapshot?
    private var renderedSnapshot: LibrarySnapshot?
    private var hotKey: GlobalHotKey?
    private var keyboardMonitor: Any?
    private var previousApp: NSRunningApplication?

    private(set) var isVisible = false

    init(service: LibraryService) {
        self.service = service
    }

    /// 覆盖层显隐变化的通知，供测试与调试观察。
    var onVisibilityChange: ((Bool) -> Void)?

    /// 注册 ⌥+Space 全局热键。注册失败（组合键被占用）时返回 false。
    @discardableResult
    func installHotKey() -> Bool {
        hotKey = GlobalHotKey(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey)
        ) { [weak self] in
            MainActor.assumeIsolated { self?.toggle() }
        }
        return hotKey != nil
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    /// 启动时先算一次快照，免得第一次按键落在冷路径上。
    func prewarm() {
        refresh()
    }

    func show() {
        guard !isVisible else { return }
        guard let screen = targetScreen() else { return }

        previousApp = NSWorkspace.shared.frontmostApplication
        model.reset()

        let window = preparedWindow(for: screen)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        installKeyboardMonitor()
        isVisible = true
        onVisibilityChange?(true)
        // 直接敲字就该进搜索框：焦点在唤起时就给上，用户不需要先点它。
        model.requestSearchFocus()

        // 唤起路径上不读盘（ticket 017 的硬性要求）：先把窗口摆出来，
        // 再让重扫描在后台跑。清单多数时候没变，`render` 会因此什么都不做。
        refresh()
    }

    /// 单击一个方块的完整语义：启动该应用并收起覆盖层。
    func activate(_ entry: ApplicationEntry) {
        service.launch(entry)
        hide()
    }

    func hide() {
        guard isVisible else { return }

        let restoreFocusTo = previousApp
        hideWithoutRestoringFocus()
        // 把焦点还给唤起覆盖层之前的前台应用，否则用户回到原应用还得再点一次。
        _ = restoreFocusTo?.activate(options: [])
    }

    /// 收起覆盖层但不把焦点还回去。
    ///
    /// 从 Dock 图标进控制台时用它：接下来要开控制台窗口，
    /// 先把焦点还给别的应用再抢回来，中间会闪一下，还可能把控制台挤掉 key window。
    func hideWithoutRestoringFocus() {
        guard isVisible else { return }

        removeKeyboardMonitor()
        window?.orderOut(nil)
        isVisible = false
        onVisibilityChange?(false)
        previousApp = nil
    }

    /// 覆盖层出现在**鼠标当前所在**的那块屏幕上。
    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let geometries = screens.map { screen in
            ScreenGeometry(
                identifier: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    .map { "\($0)" } ?? "unknown",
                frame: Rect(
                    origin: Point(x: screen.frame.origin.x, y: screen.frame.origin.y),
                    size: Size(width: screen.frame.width, height: screen.frame.height)
                )
            )
        }
        guard let index = ScreenSelector.indexOfScreen(containing: mouseLocation(), in: geometries) else {
            return nil
        }
        return screens[index]
    }

    /// `NSEvent.mouseLocation` 与 `NSScreen.frame` 同为"主屏左下角为原点、y 轴向上"的坐标系。
    private func mouseLocation() -> Point {
        let location = NSEvent.mouseLocation
        return Point(x: location.x, y: location.y)
    }

    /// 复用已建好的窗口，必要时把它挪到目标屏幕上。
    private func preparedWindow(for screen: NSScreen) -> OverlayWindow {
        let window = self.window ?? makeWindow(for: screen)
        self.window = window
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: false)
        }
        return window
    }

    /// 后台重算快照，回到主线程后再决定要不要重建视图。
    ///
    /// 扫描要读 100 多个 Info.plist，放主线程上就是一次可感知的卡顿。
    /// 这里**不**记录应用位置——覆盖层这条路上一个字节都不写盘（ticket 017）。
    private func refresh() {
        let service = self.service
        Task.detached(priority: .utility) { [weak self] in
            let snapshot = service.snapshot()
            await MainActor.run { self?.apply(snapshot) }
        }
    }

    /// 换成一份新快照。
    ///
    /// 只在快照真的变了的时候重建视图树：给 `rootView` 赋值会重跑整棵 SwiftUI 树，
    /// 而大多数变更（比如某个应用的图标补上了）本就不影响画面。窗口自始至终是同一个，
    /// 覆盖层开着的时候也只是原地换内容，不会闪。
    func apply(_ snapshot: LibrarySnapshot) {
        latestSnapshot = snapshot
        // 打开着的分组可能在控制台里被删掉了，那层子网格得自己退掉。
        model.reconcile(with: snapshot)
        guard let hostingView, snapshot != renderedSnapshot else { return }
        hostingView.rootView = rootView(for: snapshot)
        renderedSnapshot = snapshot
    }

    /// 视图的装配只此一处：建窗与换快照都从这里取，两条路不会再把
    /// `onLaunch` / `onDismiss` 接歪一个——先前建窗用的是空闭包，且要等
    /// 快照真的变了才会被换掉，磁盘没动的时候单击图标就一直不响应。
    private func rootView(for snapshot: LibrarySnapshot) -> OverlayView {
        OverlayView(
            snapshot: snapshot,
            model: model,
            onLaunch: { [weak self] entry in self?.activate(entry) },
            onDismiss: { [weak self] in self?.hide() },
            onDrop: { [weak self] level, item, point, frames in
                self?.performDrop(item, at: point, on: level, frames: frames) ?? false
            }
        )
    }

    /// 一次拖拽落地：判定、落盘、重扫。
    ///
    /// 覆盖层这条路上唯一写盘的地方。判定是纯函数（`OverlayDrop.action`），
    /// 执行走的还是控制台那几个服务方法——两个界面不可能给同一份配置算出不同结果。
    private func performDrop(
        _ item: OverlayDragItem,
        at point: Point,
        on level: OverlayModel.Level,
        frames: [Int: Rect]
    ) -> Bool {
        // 归属先对一遍：被盖住那一层的接收面还挂着（顶层的滚动区在子网格后面没拆），
        // 名字对不上就拒绝，免得子网格里的一次松手动到了顶层的顺序。
        // 搜索盖着时也不接——那会儿摆的是结果清单，不是这一层的网格。
        guard !model.isSearching, level == model.level, let snapshot = latestSnapshot else {
            return false
        }

        // TEMP（012 真机验证用，验证完删除）：确认落点回调到底有没有来。
        NSLog("[AppBox] TEMP drop: \(item) level=\(level) point=\(point)")
        let action = OverlayDrop.action(
            for: item,
            at: point,
            on: level,
            tiles: model.tiles(in: snapshot),
            frames: frames,
            in: snapshot
        )
        NSLog("[AppBox] TEMP action: \(action)")
        guard action != .rejected else { return false }

        do {
            try service.perform(action)
        } catch {
            // 服务那边的拒绝（分组没了、成员被锁了）不做成弹窗：这次拖拽的
            // 返回值会把「没接住」的动画还给用户，日志留个底就够了。
            NSLog("[AppBox] 拖拽整理失败：\(error.localizedDescription)")
            return false
        }
        // 立刻重扫：文件里的顺序就是下一次画的顺序，中间不留一份「看起来动了、
        // 其实没动」的缓冲。扫描在后台线程跑，这一帧的空窗用户感觉不到。
        refresh()
        return true
    }

    private func makeWindow(for screen: NSScreen) -> OverlayWindow {
        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Dock 是 20、菜单栏是 24、状态栏是 25，比它们高就够了。
        // 不能到 screenSaver（1000）：拖拽会话的拖影窗口固定在 dragging 层（500，
        // 实测值），源窗口一旦高过它，拖拽起得了手却永远收不了尾——事件交给
        // 会话内的嵌套循环后就再没人推进它（006/012 真机验证抓到的坑）。
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.draggingWindow)) - 1)
        // 必须能加入所有 Space 并覆盖全屏应用，否则在别的桌面或全屏应用前台时唤不出来。
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = false
        window.animationBehavior = .none

        // 第一次建窗时用预热好的那份快照，首屏立刻有内容；随后后台再校一遍。
        let hostingView = NSHostingView(
            rootView: rootView(for: latestSnapshot ?? LibrarySnapshot(groups: []))
        )
        renderedSnapshot = latestSnapshot
        self.hostingView = hostingView
        window.contentView = hostingView
        return window
    }

    /// 覆盖层可见期间接管键盘。
    ///
    /// 只在可见时安装：控制台、向导那些窗口的键盘一个字都不经过这里。
    private func installKeyboardMonitor() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 先在非隔离上下文里把要用的东西摘出来，避免把 NSEvent 带进
            // @MainActor 闭包（NSEvent 不是 Sendable）。
            let keyCode = event.keyCode
            let character = event.charactersIgnoringModifiers?.first
            let hasSystemModifier = !event.modifierFlags
                .intersection([.command, .control, .option, .function]).isEmpty

            var handled = false
            MainActor.assumeIsolated {
                // 搜索框攥着焦点时，文字与退格交给输入框自己收（输入法的组合也走它），
                // 导航键仍然由这里接管。
                let isTypingInSearchField = (NSApp.keyWindow?.firstResponder as? NSTextView)?
                    .isFieldEditor == true
                handled = self?.handleKey(
                    keyCode: keyCode,
                    character: character,
                    hasSystemModifier: hasSystemModifier,
                    isTypingInSearchField: isTypingInSearchField
                ) ?? false
            }
            // 消费掉的按键不再往响应链上走：ScrollView 自己也会响应方向键，
            // 不拦下来就会「高亮挪一格、网格又自己滚一段」。
            return handled ? nil : event
        }
    }

    private func removeKeyboardMonitor() {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
    }

    /// 返回 true 表示这次按键被覆盖层消费掉了。
    private func handleKey(
        keyCode: UInt16,
        character: Character?,
        hasSystemModifier: Bool,
        isTypingInSearchField: Bool
    ) -> Bool {
        if keyCode == UInt16(kVK_Escape) {
            // TEMP（012 真机验证用，验证完删除）：确认拖拽中按 Esc 时监听器收没收到。
            NSLog("[AppBox] TEMP Esc: isSearching=\(model.isSearching) level=\(model.level)")
            // 搜索中 Esc 先清查询（回到来时的层级），子网格里先回顶层，顶层才收起。
            if model.isSearching {
                model.clearSearch()
                model.updateSearch(in: currentSnapshot)
            } else if !model.back() {
                hide()
            }
            return true
        }

        let tiles = currentTiles()
        switch keyCode {
        case UInt16(kVK_LeftArrow):
            model.move(.left, columns: OverlayGrid.columns, in: tiles)
        case UInt16(kVK_RightArrow):
            model.move(.right, columns: OverlayGrid.columns, in: tiles)
        case UInt16(kVK_UpArrow):
            model.move(.up, columns: OverlayGrid.columns, in: tiles)
        case UInt16(kVK_DownArrow):
            model.move(.down, columns: OverlayGrid.columns, in: tiles)
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            activateSelection(in: tiles)
        case UInt16(kVK_Delete):
            // 位在输入框里时退格归它管；这里管的是"焦点不在输入框"的兜底，
            // 顺便把退格吃掉，免得系统为此响一声。
            guard !isTypingInSearchField else { return false }
            model.deleteLastQueryCharacter()
            model.updateSearch(in: currentSnapshot)
        default:
            // 方向键自身带着 .function 标记，所以修饰键这一关只卡文字这一路：
            // 带 ⌘/⌃/⌥ 的组合键留给系统与菜单（⌘Q、⌘V 之类）。
            guard !hasSystemModifier, let character, Self.isSearchInput(character) else {
                return false
            }
            // 输入框自己收字时，查询由它的绑定改、视图里的 onChange 负责重算。
            guard !isTypingInSearchField else { return false }
            model.type(String(character))
            model.updateSearch(in: currentSnapshot)
            model.requestSearchFocus()
        }
        return true
    }

    /// 敲下去该进搜索框的字符：字母、数字、标点、符号与空格。
    private static func isSearchInput(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character.isPunctuation
            || character.isSymbol || character == " "
    }

    /// 当前这一层摆着的格子。与视图画的是同一个投影（搜索时是结果清单）。
    private func currentTiles() -> [OverlayTile] {
        model.tiles(in: currentSnapshot)
    }

    private var currentSnapshot: LibrarySnapshot {
        latestSnapshot ?? LibrarySnapshot(groups: [])
    }

    /// 回车：单图标启动、方块展开——与鼠标点一下走的是同两条路。
    private func activateSelection(in tiles: [OverlayTile]) {
        switch model.activation(in: tiles) {
        case .launch(let entry):
            activate(entry)
        case .openGroup(let id):
            model.open(groupID: id)
        case nil:
            break
        }
    }
}
