// AX 树检查器：附着到运行中的 AppBox，dump 窗口的 Accessibility 树。
// 用途：在写侧边栏 AX 验收断言之前，先看清 SwiftUI 真实暴露的 role / subrole /
// title / identifier / selected 结构。纯只读，不改动界面。
//
// 用法：swiftc -O ax-probe.swift -o /tmp/ax-probe && /tmp/ax-probe [窗口标题过滤]
import AppKit
import ApplicationServices
import Foundation

func attr(_ el: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(el, key as CFString, &value)
    return err == .success ? value : nil
}

func str(_ el: AXUIElement, _ key: String) -> String? {
    attr(el, key) as? String
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func describe(_ el: AXUIElement) -> String {
    let role = str(el, kAXRoleAttribute as String) ?? "?"
    let sub = str(el, kAXSubroleAttribute as String).map { "/\($0)" } ?? ""
    let title = str(el, kAXTitleAttribute as String).map { " title=\"\($0)\"" } ?? ""
    let desc = str(el, kAXDescriptionAttribute as String).map { " desc=\"\($0)\"" } ?? ""
    let idf = str(el, kAXIdentifierAttribute as String).map { " id=\"\($0)\"" } ?? ""
    var val = ""
    if let v = attr(el, kAXValueAttribute as String) {
        let s = "\(v)"
        if s.count <= 40 { val = " value=\(s)" }
    }
    var sel = ""
    if let selected = attr(el, kAXSelectedAttribute as String) as? Bool, selected {
        sel = " [SELECTED]"
    }
    return "\(role)\(sub)\(title)\(desc)\(idf)\(val)\(sel)"
}

func actions(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success,
          let list = names as? [String] else { return [] }
    return list
}

func dump(_ el: AXUIElement, depth: Int, maxDepth: Int, showActions: Bool) {
    if depth > maxDepth { return }
    let pad = String(repeating: "  ", count: depth)
    var line = "\(pad)\(describe(el))"
    if showActions {
        let a = actions(el)
        if !a.isEmpty { line += "  actions=\(a)" }
    }
    print(line)
    for child in children(el) {
        dump(child, depth: depth + 1, maxDepth: maxDepth, showActions: showActions)
    }
}

// --- main ---
let filter = CommandLine.arguments.dropFirst().first ?? ""
let trusted = AXIsProcessTrusted()
FileHandle.standardError.write("AXIsProcessTrusted = \(trusted)\n".data(using: .utf8)!)
if !trusted {
    print("⚠️  当前进程未被授予「辅助功能」权限，AX 查询会返回空。请到 系统设置 → 隐私与安全性 → 辅助功能 勾选运行本脚本的宿主进程后重试。")
}

guard let app = NSWorkspace.shared.runningApplications.first(where: {
    $0.localizedName == "AppBox" && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
}) else {
    print("找不到运行中的 AppBox 进程")
    exit(1)
}

let pid = app.processIdentifier
let appEl = AXUIElementCreateApplication(pid)
print("附着 AppBox pid=\(pid)")

let windows = (attr(appEl, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
print("窗口数 = \(windows.count)\n")

let showActions = ProcessInfo.processInfo.environment["AX_ACTIONS"] == "1"
for (i, w) in windows.enumerated() {
    let title = str(w, kAXTitleAttribute as String) ?? "(无标题)"
    if !filter.isEmpty, !title.contains(filter) { continue }
    print("=== 窗口[\(i)] title=\"\(title)\" role=\(str(w, kAXRoleAttribute as String) ?? "?") subrole=\(str(w, kAXSubroleAttribute as String) ?? "-") ===")
    dump(w, depth: 0, maxDepth: 40, showActions: showActions)
    print("")
}
