import AppBoxCore
import AppKit
import SwiftUI

/// 物理按下的单调代数：每次 `leftMouseDown` 递增一次。
///
/// 「幽灵投递」守卫（见 `GhostDropGuard`）靠它回答「自上次离开落点以来
/// 有没有新的按下」。监听装在应用级：覆盖层、控制台里的拖拽起手都发生在
/// AppBox 自己的窗口上，一个 local monitor 全都覆盖。从别的应用拖进来
/// 不经过这里，但那种拖拽的载荷类型本来也落不到 AppBox 的落点上。
@MainActor
final class MousePressCounter {
    static let shared = MousePressCounter()

    private(set) var generation = 0
    private var monitor: Any?

    private init() {}

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.generation += 1 }
            return event
        }
    }
}

extension View {
    /// 带「幽灵投递」守卫的落点。
    ///
    /// 与 `dropDestination` 同形（载荷取第一个），但会吞掉被 Esc 取消后由
    /// 系统重放的幽灵动作——背景与判据见 `GhostDropGuard`。覆盖层与控制台的
    /// 所有落点都走这里接线，一条路径都不能漏：幽灵落在哪一处，哪一处就改数据。
    func guardedDropDestination<Payload: Transferable>(
        for payload: Payload.Type,
        onTargetedChange: ((Bool) -> Void)? = nil,
        action: @escaping (Payload, CGPoint) -> Bool
    ) -> some View {
        modifier(
            GuardedDropDestination(
                payload: payload,
                onTargetedChange: onTargetedChange,
                action: action
            )
        )
    }
}

private struct GuardedDropDestination<Payload: Transferable>: ViewModifier {
    let payload: Payload.Type
    let onTargetedChange: ((Bool) -> Void)?
    let action: (Payload, CGPoint) -> Bool

    @State private var guardState = GhostDropGuard()
    @State private var isTargeted = false
    /// 这次瞄准是不是幽灵会话。进入时判一次，动作随后到来时据此拒绝。
    @State private var ghostEntered = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: payload) { payloads, location in
                if ghostEntered {
                    // 用户的手从未在这上面松开过（Esc 取消后系统重放），
                    // 返回「接住了」把动作吞掉：既不能改数据，也不给落点动画。
                    ghostEntered = false
                    NSLog("[AppBox] 已拦截幽灵拖拽投递（Esc 取消后的系统重放）")
                    return true
                }
                guard let payload = payloads.first else { return false }
                return action(payload, location)
            } isTargeted: { targeted in
                if targeted != isTargeted {
                    if targeted {
                        ghostEntered = guardState.isGhostEnter(
                            mouseButtonDown: NSEvent.pressedMouseButtons != 0,
                            pressGeneration: MousePressCounter.shared.generation
                        )
                    } else {
                        guardState.noteLeave(pressGeneration: MousePressCounter.shared.generation)
                    }
                }
                isTargeted = targeted
                onTargetedChange?(targeted)
            }
    }
}
