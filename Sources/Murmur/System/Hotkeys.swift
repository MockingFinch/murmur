import AppKit
import Carbon.HIToolbox
import MurmurCore

/// Global shortcuts through Carbon's hot keys: they work in every app,
/// need no Accessibility permission, and swallow the key so the app in
/// front never sees it.
@MainActor
final class Hotkeys {
    enum ID: UInt32 { case toggle = 1, translate = 2, cancel = 3 }

    static let shared = Hotkeys()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var pressActions: [UInt32: () -> Void] = [:]
    private var releaseActions: [UInt32: () -> Void] = [:]
    private var installed = false

    /// Registers `shortcut`; false when another app already holds it.
    @discardableResult
    func register(_ id: ID, _ shortcut: Shortcut,
                  onRelease: (() -> Void)? = nil,
                  action: @escaping () -> Void) -> Bool {
        installIfNeeded()
        unregister(id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D52_4D52), id: id.rawValue) // "MRMR"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id.rawValue] = ref
        pressActions[id.rawValue] = action
        releaseActions[id.rawValue] = onRelease
        return true
    }

    func unregister(_ id: ID) {
        if let ref = refs.removeValue(forKey: id.rawValue) { UnregisterEventHotKey(ref) }
        pressActions[id.rawValue] = nil
        releaseActions[id.rawValue] = nil
    }

    func isRegistered(_ id: ID) -> Bool { refs[id.rawValue] != nil }

    fileprivate func firePressed(_ id: UInt32) { pressActions[id]?() }
    fileprivate func fireReleased(_ id: UInt32) { releaseActions[id]?() }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetEventDispatcherTarget(), hotKeyHandler, specs.count, &specs, nil, nil)
    }
}

private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let key = id.id
    let kind = GetEventKind(event)
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            if kind == UInt32(kEventHotKeyReleased) {
                Hotkeys.shared.fireReleased(key)
            } else {
                Hotkeys.shared.firePressed(key)
            }
        }
    }
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
