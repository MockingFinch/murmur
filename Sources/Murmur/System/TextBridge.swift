import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Reading what the user selected, and putting text where they type.
///
/// Selection, in order of trust:
/// 1. Accessibility on the focused element of the app in front: its selected
///    text, or the text of its selected range, or (web views, Chromium,
///    Electron) of its selected text marker range. A collapsed range is a
///    caret: definitely no selection, and nothing more is tried.
/// 2. Only when Accessibility cannot tell: a copy probe. The clipboard is
///    saved, ⌘C is sent, and whatever plain text appears is the selection;
///    the clipboard is then put back exactly as it was. Never in password
///    fields or under secure input, never in lists or file browsers, and
///    copied files are ignored.
///
/// Insertion: the text goes on the clipboard and stays there. Then it is
/// pasted (⌘V, so the app gets a normal undo step) into the field with the
/// caret, or else into the text field under the mouse pointer, which is
/// focused first. With neither, it is left on the clipboard for the user.
@MainActor
enum TextBridge {
    struct Selection {
        enum Source { case accessibility, copyProbe }
        let text: String
        let pid: pid_t
        let element: AXUIElement?
        let source: Source
    }

    enum PasteOutcome: Equatable {
        case pasted
        /// Not typed: left on the clipboard, for the reason given.
        case copied(String)
    }

    // MARK: Selection

    static func readSelection() async -> Selection? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let pid = app.processIdentifier
        AccessibilityBooster.shared.boost(app)

        let element = focusedElement(pid: pid)
        if let element {
            if isSecure(element) { return nil }
            switch probe(element) {
            case .text(let s): return Selection(text: s, pid: pid, element: element, source: .accessibility)
            case .caret: return nil
            case .unknown: break
            }
            if !allowsCopyProbe(element) { return nil }
        }
        if IsSecureEventInputEnabled() { return nil }
        guard let copied = await copyProbe() else { return nil }
        return Selection(text: copied, pid: pid, element: element, source: .copyProbe)
    }

    /// Whether `selection` is still what is selected, in the same app and
    /// field, so a paste would replace it.
    static func isStillSelected(_ selection: Selection) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == selection.pid else { return false }
        guard let original = selection.element else { return true }
        guard let now = focusedElement(pid: selection.pid) else { return selection.source == .copyProbe }
        guard CFEqual(now, original) else { return false }
        switch probe(now) {
        case .text(let s): return s == selection.text
        case .caret: return false
        case .unknown: return true
        }
    }

    private enum Probe { case text(String), caret, unknown }

    private static func probe(_ e: AXUIElement) -> Probe {
        if let s = stringAttribute(e, kAXSelectedTextAttribute), !s.isEmpty {
            return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .caret : .text(s)
        }
        if let range = selectedRange(e) {
            if range.length == 0 { return .caret }
            var r = range
            if let value = AXValueCreate(.cfRange, &r) {
                var out: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(e, kAXStringForRangeParameterizedAttribute as CFString, value, &out) == .success,
                   let s = out as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return .text(s)
                }
            }
            return .unknown
        }
        var marker: CFTypeRef?
        if AXUIElementCopyAttributeValue(e, "AXSelectedTextMarkerRange" as CFString, &marker) == .success, let marker {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(e, "AXStringForTextMarkerRange" as CFString, marker, &out) == .success,
               let s = out as? String {
                return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .caret : .text(s)
            }
        }
        return .unknown
    }

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        if let e = elementAttribute(app, kAXFocusedUIElementAttribute) { return e }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        return elementAttribute(system, kAXFocusedUIElementAttribute)
    }

    private static func isSecure(_ e: AXUIElement) -> Bool {
        stringAttribute(e, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String)
    }

    /// Places where ⌘C copies something other than text.
    private static let noProbeRoles: Set<String> = [
        "AXList", "AXOutline", "AXTable", "AXBrowser", "AXRow", "AXCell", "AXGrid", "AXImage",
        "AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXSlider", "AXDockItem",
    ]

    private static func allowsCopyProbe(_ e: AXUIElement) -> Bool {
        guard let role = stringAttribute(e, kAXRoleAttribute) else { return true }
        return !noProbeRoles.contains(role)
    }

    private static func copyProbe() async -> String? {
        await waitForModifierRelease()
        let pb = NSPasteboard.general
        let saved = Clipboard.snapshot(pb)
        let before = pb.changeCount
        postKey(UInt16(kVK_ANSI_C), flags: .maskCommand)

        var changed = false
        for _ in 0 ..< 30 { // up to 300 ms
            try? await Task.sleep(nanoseconds: 10_000_000)
            if pb.changeCount != before { changed = true; break }
        }
        guard changed else { return nil }
        // Give a lazy app a moment to finish writing every type.
        try? await Task.sleep(nanoseconds: 20_000_000)
        let types = pb.types ?? []
        let isFiles = types.contains(.fileURL) || types.contains(NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        let text = isFiles ? nil : pb.string(forType: .string)
        Clipboard.restore(pb, saved)
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    // MARK: Insertion

    static func paste(_ text: String) async -> PasteOutcome {
        Clipboard.put(text)
        guard AXIsProcessTrusted() else {
            return .copied("Allow Accessibility so Murmur can type for you. Paste with ⌘V.")
        }
        if IsSecureEventInputEnabled() {
            return .copied("Secure input is on, so Murmur can't type here. Paste with ⌘V.")
        }
        await waitForModifierRelease()

        switch findTarget() {
        case .caret, .unknown:
            break
        case .pointer(let element, let point):
            guard await focus(element, at: point) else {
                return .copied("Couldn't reach the field under the pointer. Paste with ⌘V.")
            }
        case .nowhere:
            return .copied("No text field at the cursor or under the pointer. Paste with ⌘V.")
        }
        postKey(UInt16(kVK_ANSI_V), flags: .maskCommand)
        return .pasted
    }

    // MARK: Where the text goes

    private enum Target {
        /// The focused element takes text.
        case caret
        /// No caret in a text field, but the pointer is over one.
        case pointer(AXUIElement, CGPoint)
        /// The app in front doesn't say what has focus: paste and hope, as a person would.
        case unknown
        /// Focus is somewhere that takes no text, and the pointer isn't over a field.
        case nowhere
    }

    private static func findTarget() -> Target {
        let front = NSWorkspace.shared.frontmostApplication
        let focused = front.flatMap { focusedElement(pid: $0.processIdentifier) }
        if let focused, isEditable(focused) { return .caret }
        if let (element, point) = editableUnderPointer() { return .pointer(element, point) }
        if let focused, let role = stringAttribute(focused, kAXRoleAttribute), notTextRoles.contains(role) { return .nowhere }
        return .unknown
    }

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Roles that are surely not somewhere to type.
    private static let notTextRoles: Set<String> = [
        "AXList", "AXOutline", "AXTable", "AXBrowser", "AXRow", "AXCell", "AXGrid", "AXImage", "AXButton",
        "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider",
        "AXDockItem", "AXLink", "AXStaticText", "AXWebArea", "AXScrollArea", "AXSplitGroup", "AXTabGroup",
        "AXToolbar", "AXWindow", "AXApplication", "AXDisclosureTriangle",
    ]

    /// Whether an element takes typed text: a text control, something inside
    /// an editable web region, or anything with a settable value and a caret.
    private static func isEditable(_ e: AXUIElement) -> Bool {
        if isSecure(e) { return false }
        if let role = stringAttribute(e, kAXRoleAttribute), textRoles.contains(role) { return true }
        if elementAttribute(e, "AXEditableAncestor") != nil { return true }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(e, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue,
           selectedRange(e) != nil {
            return true
        }
        return false
    }

    /// The text field under the mouse pointer (or the field a hit lands
    /// inside), with the point in screen coordinates (top-left origin).
    private static func editableUnderPointer() -> (AXUIElement, CGPoint)? {
        let mouse = NSEvent.mouseLocation
        guard let primary = NSScreen.screens.first else { return nil }
        let point = CGPoint(x: mouse.x, y: primary.frame.maxY - mouse.y)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid == ProcessInfo.processInfo.processIdentifier { return nil }
        for _ in 0 ..< 6 {
            if isEditable(element) { return (element, point) }
            guard let parent = elementAttribute(element, kAXParentAttribute) else { break }
            element = parent
        }
        return nil
    }

    /// Gives the field the caret: through Accessibility when its app is in
    /// front, otherwise with a click where the pointer already is (which
    /// also brings its window forward).
    private static func focus(_ element: AXUIElement, at point: CGPoint) async -> Bool {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let inFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        if inFront, AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
            try? await Task.sleep(nanoseconds: 60_000_000)
            if let now = focusedElement(pid: pid), isEditable(now) { return true }
        }
        click(at: point)
        try? await Task.sleep(nanoseconds: 220_000_000)
        guard let now = focusedElement(pid: pid) else { return true }
        return isEditable(now) || !(stringAttribute(now, kAXRoleAttribute).map(notTextRoles.contains) ?? false)
    }

    private static func click(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    // MARK: Keys

    /// The user's own fingers may still be on ⌃ from the shortcut: a key
    /// sent now would arrive as ⌃⌘V. Wait (briefly) for them to let go.
    static func waitForModifierRelease(timeout: TimeInterval = 0.6) async {
        let mask: CGEventFlags = [.maskControl, .maskCommand, .maskAlternate, .maskShift]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if CGEventSource.flagsState(.combinedSessionState).intersection(mask).isEmpty { return }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    static func postKey(_ key: UInt16, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: AX helpers

    private static func stringAttribute(_ e: AXUIElement, _ attribute: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success, let v else { return nil }
        if let s = v as? String { return s }
        if let a = v as? NSAttributedString { return a.string }
        return nil
    }

    private static func elementAttribute(_ e: AXUIElement, _ attribute: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func selectedRange(_ e: AXUIElement) -> CFRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &range) ? range : nil
    }
}

/// The whole clipboard, every item and type, to put back later.
@MainActor
enum Clipboard {
    static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let d = item.data(forType: t) { types[t] = d } }
            return types
        }
    }

    static func restore(_ pb: NSPasteboard, _ snapshot: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        guard !snapshot.isEmpty else { return }
        pb.writeObjects(snapshot.map { types in
            let item = NSPasteboardItem()
            for (t, d) in types { item.setData(d, forType: t) }
            return item
        })
    }

    /// Puts text on the clipboard to stay: an ordinary copy, which clipboard
    /// managers may keep.
    static func put(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

/// Chromium and Electron build their accessibility tree only when asked.
/// Asking as an app comes to the front means the tree is there by the
/// time the shortcut is pressed.
@MainActor
final class AccessibilityBooster {
    static let shared = AccessibilityBooster()
    private var boosted = Set<pid_t>()
    private var observers: [NSObjectProtocol] = []

    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { AccessibilityBooster.shared.boost(app) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { _ = AccessibilityBooster.shared.boosted.remove(app.processIdentifier) }
        })
        if let front = NSWorkspace.shared.frontmostApplication { boost(front) }
    }

    func boost(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard AXIsProcessTrusted(), !boosted.contains(pid), isChromiumBased(app) else { return }
        boosted.insert(pid)
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.3)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func isChromiumBased(_ app: NSRunningApplication) -> Bool {
        if let id = app.bundleIdentifier, Self.chromiumBrowsers.contains(id) { return true }
        guard let url = app.bundleURL else { return false }
        let electron = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: electron.path)
    }
}
