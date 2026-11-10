import AppKit
import Carbon.HIToolbox
import MurmurCore

/// Global shortcuts through Carbon's hot keys: they work in every app,
/// need no Accessibility permission, and swallow the key so the app in
/// front never sees it.
@MainActor
final class Hotkeys {
    enum ID: UInt32 { case toggle = 1, translate = 2 }

    static let shared = Hotkeys()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var installed = false

    /// Registers `shortcut`; false when another app already holds it.
    @discardableResult
    func register(_ id: ID, _ shortcut: Shortcut, action: @escaping () -> Void) -> Bool {
        installIfNeeded()
        unregister(id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D52_4D52), id: id.rawValue) // "MRMR"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id.rawValue] = ref
        actions[id.rawValue] = action
        return true
    }

    func unregister(_ id: ID) {
        if let ref = refs.removeValue(forKey: id.rawValue) { UnregisterEventHotKey(ref) }
        actions[id.rawValue] = nil
    }

    func isRegistered(_ id: ID) -> Bool { refs[id.rawValue] != nil }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), hotKeyHandler, 1, &spec, nil, nil)
    }
}

private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let key = id.id
    DispatchQueue.main.async { MainActor.assumeIsolated { Hotkeys.shared.fire(key) } }
    return noErr
}

extension Shortcut {
    /// Carbon modifier bits from AppKit's.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= Shortcut.control }
        if flags.contains(.option) { m |= Shortcut.option }
        if flags.contains(.shift) { m |= Shortcut.shift }
        if flags.contains(.command) { m |= Shortcut.command }
        return m
    }
}
