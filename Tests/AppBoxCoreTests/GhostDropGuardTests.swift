import Foundation
import Testing

@testable import AppBoxCore

/// 幽灵守卫的判定矩阵。
///
/// 三个输入维度：有没有离开记录、进入时按钮状态、按下代数是否推进。
/// 真机场景对应：V1 幽灵（离开后无新按下 + 按钮已抬）、V2 正常拖放
/// （按钮按着）、V3 快速擦边（首次进入、无离开记录）、取消后用户重新拖来
/// （离开后有过新按下）。
@Suite("拖拽：幽灵投递守卫")
struct GhostDropGuardTests {
    @Test("从未离开过的进入不是幽灵")
    func firstEnterIsNeverGhost() {
        var guardState = GhostDropGuard()
        let ghost = guardState.isGhostEnter(mouseButtonDown: false, pressGeneration: 7)
        #expect(ghost == false)
    }

    @Test("离开后无新按下且按钮已抬起 = 幽灵")
    func leaveThenStaleEnterIsGhost() {
        var guardState = GhostDropGuard()
        guardState.noteLeave(pressGeneration: 7)
        let ghost = guardState.isGhostEnter(mouseButtonDown: false, pressGeneration: 7)
        #expect(ghost)
    }

    @Test("离开后有过新的按下 = 新一次真实拖拽，不是幽灵")
    func enterAfterNewPressIsReal() {
        var guardState = GhostDropGuard()
        guardState.noteLeave(pressGeneration: 7)
        // 用户重新按住（代数推进到 8）再拖进来。
        let ghost = guardState.isGhostEnter(mouseButtonDown: false, pressGeneration: 8)
        #expect(ghost == false)
    }

    @Test("进入时按钮还按着 = 真实拖拽，不是幽灵")
    func enterWhileButtonDownIsReal() {
        var guardState = GhostDropGuard()
        guardState.noteLeave(pressGeneration: 7)
        let ghost = guardState.isGhostEnter(mouseButtonDown: true, pressGeneration: 7)
        #expect(ghost == false)
    }

    @Test("判断之后又离开，再进入按新记录重新判定")
    func leaveUpdatesRecord() {
        var guardState = GhostDropGuard()
        guardState.noteLeave(pressGeneration: 7)
        let firstGhost = guardState.isGhostEnter(mouseButtonDown: false, pressGeneration: 7)
        #expect(firstGhost)
        // 用户真实拖走（离开时已是新一次按下之后的代数），后一个幽灵再来。
        guardState.noteLeave(pressGeneration: 9)
        let secondGhost = guardState.isGhostEnter(mouseButtonDown: false, pressGeneration: 9)
        #expect(secondGhost)
    }
}
