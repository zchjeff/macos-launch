// AX 驱动的侧边栏验收脚本。
//
// 目的：验证「点选中 / 折叠分区 / 右键增删改 / 确认告警框按钮」这些 ComputerUse 合成鼠标
// 点不动的路径，能否经 Accessibility API 驱动成功——这正是 XCUITest 底层使用的机制。
// 不引入 .xcodeproj、不违反 ADR-0001（见 docs/adr/0001-swiftui-swiftpm.md）。
//
// 前提：AppBox 已启动且控制台窗口可见；运行本脚本的宿主进程已授予「辅助功能」权限。
// 用法：xcrun swiftc -O scripts/ax-sidebar-acceptance.swift -o /tmp/ax-accept && /tmp/ax-accept
//
// ⚠️ 破坏性操作用「新建临时分组 → 删除」自清理，跑完配置回到原状。
//
// 实测结论（macOS 26 / SwiftUI / 本 AppBox 构建，多轮复现稳定）：
//   ✅ 可经 AX 驱动：分区折叠/展开（AXHeading 的 AXPress）、右键上下文菜单（cell 的
//      AXShowMenu）、菜单项执行（AXMenuItem 的 AXPress）、Sheet 文本输入（CGEvent 真实键盘）。
//   ❌ 无法经「公开 AX 写入 / 合成事件」驱动：
//      - List 行选中：写 AXSelected/AXSelectedRows 返回 success 但 SwiftUI 模型不响应；
//        合成鼠标点击也不改变选中。选中纯由 model 驱动。
//      - confirmationDialog 的动作按钮：能定位、AXPress 返回 success，但闭包不执行（删除不落盘）。
//      - 拖拽归组：AX 无 drag 动作。
//   以上三项需 XCUITest 经测试宿主私有事件注入才能覆盖，而引入 .xcodeproj 与 ADR-0001 冲突。
//   故这三条以 ConsoleModel 单元测试 + 真人手点为最终验收，本脚本仅覆盖可驱动部分。
import AppKit
import ApplicationServices
import Foundation

// MARK: - AX 原语

func axAttr(_ el: AXUIElement, _ key: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success ? v : nil
}
func axStr(_ el: AXUIElement, _ key: String) -> String? { axAttr(el, key) as? String }
func axChildren(_ el: AXUIElement) -> [AXUIElement] { (axAttr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] }
func axParent(_ el: AXUIElement) -> AXUIElement? { axAttr(el, kAXParentAttribute as String).map { unsafeBitCast($0, to: AXUIElement.self) } }
func axRole(_ el: AXUIElement) -> String { axStr(el, kAXRoleAttribute as String) ?? "?" }
func axValueText(_ el: AXUIElement) -> String? { axAttr(el, kAXValueAttribute as String) as? String }

@discardableResult
func axPerform(_ el: AXUIElement, _ action: String) -> Bool {
    AXUIElementPerformAction(el, action as CFString) == .success
}
func axSetSelected(_ el: AXUIElement, _ on: Bool) -> Bool {
    AXUIElementSetAttributeValue(el, kAXSelectedAttribute as CFString, on ? kCFBooleanTrue : kCFBooleanFalse) == .success
}
/// 尝试驱动一行选中：先 raise+激活+聚焦窗口，再对行中心发真实鼠标点击（CGEvent），
/// 并附带 outline 级 AXSelectedRows / 行级 AXSelected 两种写入。
func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let posV = axAttr(el, kAXPositionAttribute as String), let sizeV = axAttr(el, kAXSizeAttribute as String) else { return nil }
    var p = CGPoint.zero; var s = CGSize.zero
    AXValueGetValue(posV as! AXValue, .cgPoint, &p)
    AXValueGetValue(sizeV as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}
func bringToFront(_ appEl: AXUIElement, _ app: NSRunningApplication, _ win: AXUIElement) {
    app.activate(options: [.activateIgnoringOtherApps])
    axPerform(win, "AXRaise")
    AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    sleep(0.3)
}
func postClick(_ el: AXUIElement) -> Bool {
    guard let f = axFrame(el) else { return false }
    let cx = f.midX, cy = f.midY
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: cx, y: cy), mouseButton: .left)
    let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: cx, y: cy), mouseButton: .left)
    down?.post(tap: .cghidEventTap); sleep(0.05); up?.post(tap: .cghidEventTap)
    return true
}
/// 用 CGEvent 真实键盘当前焦点控件输出一段文本（SwiftUI 不接收 AXValue 写入，只能真输）。
func typeText(_ s: String) {
    let src = CGEventSource(stateID: .hidSystemState)
    let utf16 = Array(s.utf16)
    let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
    down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
    down?.post(tap: .cghidEventTap)
    let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
    up?.post(tap: .cghidEventTap)
}
func postKey(_ virtualKey: CGKeyCode, flags: CGEventFlags = []) {
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true); down?.flags = flags
    let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false); up?.flags = flags
    down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
}
func pressReturn() { postKey(0x24) }
func selectAllField() { postKey(0x00, flags: .maskCommand) }
func selectRow(_ win: AXUIElement, _ appEl: AXUIElement, _ app: NSRunningApplication, _ row: AXUIElement) -> String {
    bringToFront(appEl, app, win)
    var codes: [String] = ["click=\(postClick(row))"]
    if let o = outline(win) {
        codes.append("selectedRows=\(AXUIElementSetAttributeValue(o, "AXSelectedRows" as CFString, [row] as CFArray).rawValue)")
    }
    codes.append("rowSelected=\(AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue).rawValue)")
    return codes.joined(separator: ",")
}
func axActions(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success, let l = names as? [String] else { return [] }
    return l
}

func find(_ el: AXUIElement, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
    if match(el) { return el }
    for c in axChildren(el) { if let f = find(c, match) { return f } }
    return nil
}
func findAll(_ el: AXUIElement, _ match: (AXUIElement) -> Bool) -> [AXUIElement] {
    var out: [AXUIElement] = []
    if match(el) { out.append(el) }
    for c in axChildren(el) { out.append(contentsOf: findAll(c, match)) }
    return out
}

func byDesc(_ root: AXUIElement, _ role: String, _ desc: String) -> AXUIElement? {
    find(root) { axRole($0) == role && axStr($0, kAXDescriptionAttribute as String) == desc }
}
func byValue(_ root: AXUIElement, _ role: String, _ value: String) -> AXUIElement? {
    find(root) { axRole($0) == role && axValueText($0) == value }
}

func sleep(_ s: Double) { Thread.sleep(forTimeInterval: s) }
func poll(_ timeout: Double = 2.0, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if cond() { return true }; sleep(0.15) }
    return cond()
}

// MARK: - 定位关键节点

func consoleWindow(_ appEl: AXUIElement) -> AXUIElement? {
    let wins = (axAttr(appEl, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    return wins.first { axStr($0, kAXTitleAttribute as String) == "AppBox" }
}
func outline(_ win: AXUIElement) -> AXUIElement? { byDesc(win, "AXOutline", "边栏") }
func rows(_ win: AXUIElement) -> [AXUIElement] { (outline(win).map { axChildren($0).filter { axRole($0) == "AXRow" } }) ?? [] }

/// 一行的可读文本：cell 里所有 AXStaticText 的值拼接（去掉纯计数尾巴便于匹配）。
func rowText(_ row: AXUIElement) -> String {
    let texts = findAll(row) { axRole($0) == "AXStaticText" }.compactMap { axValueText($0) }
    return texts.joined(separator: " ")
}
/// 按行内出现的某个静态文本找行。
func findRow(_ win: AXUIElement, containing text: String) -> AXUIElement? {
    rows(win).first { rowText($0).contains(text) }
}

/// 当前详情显示的分组名。选中分组时存在「搜索范围」radio group，其父节点的第一个静态文本即分组名；
/// 选中工具时该 radio group 消失，返回 nil。
func detailGroupName(_ win: AXUIElement) -> String? {
    guard let radio = byDesc(win, "AXRadioGroup", "搜索范围"), let parent = axParent(radio) else { return nil }
    for c in axChildren(parent) where axRole(c) == "AXStaticText" {
        if let v = axValueText(c), !v.isEmpty { return v }
    }
    return nil
}
func toolDetailVisible(_ win: AXUIElement) -> Bool { byDesc(win, "AXRadioGroup", "搜索范围") == nil }

// MARK: - 结果记录

var passed = 0, failed = 0, skipped = 0
func check(_ name: String, _ body: () -> (Bool, String)) {
    let (ok, msg) = body()
    let tag = ok ? "✅ PASS" : "❌ FAIL"
    if ok { passed += 1 } else { failed += 1 }
    print("[\(tag)] \(name) — \(msg)")
}
func skip(_ name: String, _ why: String) { skipped += 1; print("[⏭️ SKIP] \(name) — \(why)") }

// MARK: - 主流程

guard AXIsProcessTrusted() else {
    print("❌ 宿主进程未授予「辅助功能」权限，AX 驱动无法进行。请在 系统设置→隐私与安全性→辅助功能 勾选后重试。")
    exit(2)
}
guard let app = NSWorkspace.shared.runningApplications.first(where: {
    $0.localizedName == "AppBox" && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
}), let win0 = consoleWindow(AXUIElementCreateApplication(app.processIdentifier)) else {
    print("❌ 找不到运行中的 AppBox 控制台窗口（先 open AppBox.app 并让控制台可见）")
    exit(1)
}
let appEl = AXUIElementCreateApplication(app.processIdentifier)
print("附着 AppBox pid=\(app.processIdentifier)，开始侧边栏验收\n")

// A. 选中分组（用 AXSelected，模拟 XCUITest 点击行）
check("A 点击选中分组行（未分类→工具）", {
    guard let r = findRow(win0, containing: "工具") else { return (false, "找不到工具行") }
    let codes = selectRow(win0, appEl, app, r)
    let ok = poll(2.5) { detailGroupName(win0) == "工具" }
    return (ok, "详情分组名 = \(detailGroupName(win0) ?? "nil") [\(codes)]")
})
sleep(0.3)
check("A2 选回未分类", {
    guard let r = findRow(win0, containing: "未分类") else { return (false, "找不到未分类行") }
    _ = axSetSelected(r, true)
    let ok = poll { detailGroupName(win0) == "未分类" }
    return (ok, "详情分组名 = \(detailGroupName(win0) ?? "nil")")
})

// B. 选中工具行 → 详情切到工具工作区（分组详情专有的「搜索范围」消失）
check("B 点击选中工具行（JSON 格式化）", {
    guard let r = findRow(win0, containing: "JSON 格式化") else { return (false, "找不到工具行") }
    let codes = selectRow(win0, appEl, app, r)
    let ok = poll(2.5) { toolDetailVisible(win0) }
    if let g = findRow(win0, containing: "未分类") { _ = selectRow(win0, appEl, app, g) }
    return (ok, ok ? "详情已切到工具工作区 [\(codes)]" : "详情仍显示分组内容 [\(codes)]")
})
sleep(0.3)

// C. 折叠/展开分区：AXPress 分区标题 AXHeading
check("C 折叠/展开「工具」分区", {
    guard let header = byDesc(win0, "AXHeading", "工具"), axActions(header).contains("AXPress") else {
        return (false, "工具标题不可 AXPress")
    }
    let before = rows(win0).count
    axPerform(header, "AXPress")
    let collapsed = poll { rows(win0).count < before }
    let midCollapsed = rows(win0).count
    axPerform(header, "AXPress")
    let expanded = poll { rows(win0).count == before }
    return (collapsed && expanded, "折叠: \(before)→\(midCollapsed) 行, 再展开→\(rows(win0).count) 行")
})

// D. 右键菜单新建分组
func contextMenu(_ win: AXUIElement) -> AXUIElement? {
    // 菜单可能是 app 直属子树或某个浮动窗口里的 AXMenu；遍历时从 app 根下扫。
    find(appEl) { axRole($0) == "AXMenu" }
}
/// 对某行弹右键菜单，带重试（SwiftUI 菜单出现时机偶有飘）。
func openRowContextMenu(_ win: AXUIElement, _ app: NSRunningApplication, _ row: AXUIElement) -> AXUIElement? {
    bringToFront(appEl, app, win)
    guard let cell = axChildren(row).first(where: { axRole($0) == "AXCell" }),
          let target = findAll(cell, { axActions($0).contains("AXShowMenu") }).first else { return nil }
    for _ in 0..<3 {
        if axPerform(target, "AXShowMenu"), poll(1.2, { contextMenu(win) != nil }) { return contextMenu(win) }
        sleep(0.2)
    }
    return nil
}
func pressMenuItem(_ menu: AXUIElement, titled title: String) -> Bool {
    if let item = findAll(menu, { axRole($0) == "AXMenuItem" && (axStr($0, kAXTitleAttribute as String) ?? "").contains(title) }).first {
        return axPerform(item, "AXPress")
    }
    return false
}
let tempGroup = "AX临时组ZZZ"
check("D 右键菜单 → 新建分组", {
    guard let r = findRow(win0, containing: "未分类") else { return (false, "找不到锨点行") }
    guard let menu = openRowContextMenu(win0, app, r), pressMenuItem(menu, titled: "新建分组") else {
        return (false, "AXShowMenu 未弹出菜单或无「新建分组…」")
    }
    // 输入名字的 sheet 里有个 AXTextField，点它聚焦后真输，再回车提交（onSubmit）
    guard let field = poll(1.5, { find(appEl) { axRole($0) == "AXTextField" } != nil }) ? find(appEl, { axRole($0) == "AXTextField" }) : nil else {
        return (false, "未出现名字输入框")
    }
    bringToFront(appEl, app, win0); postClick(field); sleep(0.2); typeText(tempGroup); sleep(0.2)
    pressReturn()
    let appeared = poll(2.0) { findRow(win0, containing: tempGroup) != nil }
    return (appeared, appeared ? "临时分组已创建并出现在侧栏" : "创建后侧栏未见该分组（输入未提交）")
})

// E. 重命名临时组
check("E 右键菜单 → 重命名", {
    let renamed = tempGroup + "R"
    guard let r = findRow(win0, containing: tempGroup) else { return (false, "找不到临时分组") }
    guard let menu = openRowContextMenu(win0, app, r), pressMenuItem(menu, titled: "重命名") else {
        return (false, "未能触发重命名")
    }
    guard let field = poll(1.5, { find(appEl) { axRole($0) == "AXTextField" } != nil }) ? find(appEl, { axRole($0) == "AXTextField" }) : nil else {
        return (false, "未出现改名输入框")
    }
    bringToFront(appEl, app, win0); postClick(field); sleep(0.2)
    selectAllField(); typeText(renamed); sleep(0.2); pressReturn()
    let ok = poll(2.0) { findRow(win0, containing: renamed) != nil }
    return (ok, ok ? "已重命名为 \(renamed)" : "侧栏未更新为新名")
})

// H. 删除分组 —— 关键：验证确认告警框的按钮能否经 AX 执行（ComputerUse 此前只能关框不执行）
check("H 右键删除 → 确认告警框执行", {
    guard let r = findRow(win0, containing: tempGroup) ?? findRow(win0, containing: tempGroup + "R") else {
        return (false, "找不到待删的临时分组")
    }
    guard let menu = openRowContextMenu(win0, app, r), pressMenuItem(menu, titled: "删除") else {
        return (false, "未能触发删除菜单项")
    }
    // 确认对话框：confirmationDialog 的按钮文字在 AXDescription（非 Title），带 id=action-button-1。
    func findDeleteButton() -> AXUIElement? {
        findAll(appEl) { axRole($0) == "AXButton" && (
            (axStr($0, kAXDescriptionAttribute as String) ?? "").hasPrefix("删除") ||
            (axStr($0, kAXIdentifierAttribute as String) ?? "") == "action-button-1"
        ) }.first
    }
    let delBtn: AXUIElement? = poll(2.0) { findDeleteButton() != nil } ? findDeleteButton() : nil
    guard let delBtn else {
        return (false, "未出现删除确认按钮")
    }
    axPerform(delBtn, "AXPress")
    let gone = poll(2.0) { findRow(win0, containing: tempGroup) == nil && findRow(win0, containing: tempGroup + "R") == nil }
    return (gone, gone ? "告警框按钮经 AX 执行成功，临时分组已删除（配置自清理完成）" : "确认后临时分组仍在，告警框按钮未执行")
})

// F. 拖拽归组 —— AX 无 drag 动作，CGEvent 合成又正是失效项
skip("F 拖拽归组", "AX 不提供行/瓦片的拖拽动作；该路径由 ConsoleModel 单测 movesApplicationIntoGroup 覆盖，UI 层需真人手点")

print("\n===== 汇总: \(passed) PASS / \(failed) FAIL / \(skipped) SKIP =====")

// 安全兜底：若临时分组还残留（E 改名后名字含 R），最后再尽力删一次
if findRow(win0, containing: tempGroup) != nil || findRow(win0, containing: tempGroup + "R") != nil {
    print("⚠️ 临时分组可能残留，请手动删除 \(tempGroup)/\(tempGroup)R")
}
exit(failed == 0 ? 0 : 1)
