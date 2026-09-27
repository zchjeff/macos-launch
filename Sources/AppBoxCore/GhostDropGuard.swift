import Foundation

/// 「幽灵投递」的识别。
///
/// 背景（012 真机探针实测）：拖拽中途按 Esc 取消后，系统会在约 290ms 后
/// 合成一个瞬时拖拽会话，把光标下那个落点完整走一遍 enter → perform、
/// 且携带原始载荷——SwiftUI 的 `dropDestination` 与 AppKit 的
/// `NSDraggingDestination` 都会收到。不拦它，按了 Esc 数据照样被改。
///
/// 判据（两条同时成立才算幽灵）：
/// 1. 落点被瞄准（enter）时物理鼠标按钮已抬起——真实拖拽的进入必然按着；
/// 2. 自上次离开该落点以来没有任何新的鼠标按下——幽灵会话没有起手按下，
///    而每一次真实拖拽都带着一次新的按下（按下代数随之推进）。
///
/// 判错的方向是安全的：把真实落点误判成幽灵不过是这一次拖拽没生效；
/// 把幽灵放行却会改数据。已知的误判窗口只有一个且极窄：拖拽中光标划出
/// 落点又划回、且恰好划回的那一帧松手，可能被当成幽灵（探针未实测到，
/// 因「划回的 enter 回调必须迟到到松手之后」才会触发）。
public struct GhostDropGuard: Equatable, Sendable {
    private var pressGenerationAtLeave: Int?

    public init() {}

    /// 落点失去瞄准（isTargeted 变 false）时记下当前的按下代数。
    public mutating func noteLeave(pressGeneration: Int) {
        pressGenerationAtLeave = pressGeneration
    }

    /// 落点获得瞄准（isTargeted 变 true）时判定：这次进入是不是幽灵会话。
    ///
    /// 从未离开过的进入不是幽灵：幽灵必然跟在一次「取消导致的离开」之后。
    public mutating func isGhostEnter(mouseButtonDown: Bool, pressGeneration: Int) -> Bool {
        guard !mouseButtonDown, let generationAtLeave = pressGenerationAtLeave else {
            return false
        }
        return generationAtLeave == pressGeneration
    }
}
