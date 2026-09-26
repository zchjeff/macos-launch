import Carbon.HIToolbox
import Foundation

/// 全局热键。
///
/// 走 Carbon 的 `RegisterEventHotKey` 而不是 `CGEventTap`，因此**不需要**「辅助功能」权限（ADR-0006）。
final class GlobalHotKey {
    /// Carbon 的事件回调是 C 函数指针，不携带上下文，只能按 `EventHotKeyID.id` 查表找回调用方。
    private static let lock = NSLock()
    nonisolated(unsafe) private static var actions: [UInt32: @Sendable () -> Void] = [:]
    nonisolated(unsafe) private static var nextID: UInt32 = 1
    nonisolated(unsafe) private static var handlerInstalled = false

    private static let signature: OSType = 0x4142_4F58  // 'ABOX'

    private let id: UInt32
    private var ref: EventHotKeyRef?

    /// 注册全局热键。组合键已被系统或其他应用占用时返回 nil。
    ///
    /// `action` 保证在**主线程**被调用。
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping @Sendable () -> Void) {
        Self.installHandlerIfNeeded()

        Self.lock.lock()
        let id = Self.nextID
        Self.nextID += 1
        Self.lock.unlock()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return nil }

        self.id = id
        self.ref = ref
        Self.lock.lock()
        Self.actions[id] = action
        Self.lock.unlock()
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.lock.lock()
        Self.actions[id] = nil
        Self.lock.unlock()
    }

    private static func installHandlerIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }

                GlobalHotKey.lock.lock()
                let action = GlobalHotKey.actions[hotKeyID.id]
                GlobalHotKey.lock.unlock()

                // 应用级 Carbon 事件处理器在主线程触发，但仍显式派发一次，
                // 免得把"当前恰好在主线程"变成一个隐式依赖。
                if let action {
                    DispatchQueue.main.async(execute: action)
                }
                return noErr
            },
            1,
            &spec,
            nil,
            nil
        )
    }
}
