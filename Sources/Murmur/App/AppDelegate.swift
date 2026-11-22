import AppKit
import Carbon.HIToolbox
import MurmurCore
import SwiftUI

/// Murmur's two global shortcuts: one dictates, one dictates and
/// translates. Each is installed, or set aside while it's re-recorded.
@MainActor
enum AppHotkey: CaseIterable {
    case dictate, translate

    var id: Hotkeys.ID { self == .dictate ? .toggle : .translate }
    var intent: DictationEngine.Intent { self == .dictate ? .dictate : .translate }
    var defaultShortcut: Shortcut { self == .dictate ? .default : .translateDefault }
    /// What the other shortcut is for, to explain a clash.
    var role: String { self == .dictate ? "dictation" : "translation" }

    var shortcut: Shortcut {
        get { self == .dictate ? AppSettings.shared.shortcut : AppSettings.shared.translateShortcut }
        nonmutating set {
            if self == .dictate { AppSettings.shared.shortcut = newValue } else { AppSettings.shared.translateShortcut = newValue }
        }
    }

    var other: AppHotkey { self == .dictate ? .translate : .dictate }

    @discardableResult
    func install(_ shortcut: Shortcut) -> Bool {
        let intent = self.intent
        return Hotkeys.shared.register(
            id, shortcut,
            onRelease: { DictationEngine.shared.release(intent) },
            action: { DictationEngine.shared.press(intent) }
        )
    }

    func suspend() { Hotkeys.shared.unregister(id) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let engine = DictationEngine.shared
    private let settings = AppSettings.shared
    private var hud: HUDController?
    private var statusItem: NSStatusItem?
    private var window: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = MainMenu.make(target: self)

        hud = HUDController(model: engine.hud)
        setUpStatusItem()
        AccessibilityBooster.shared.start()
        if settings.llmUsesOpenRouter { ModelCatalog.shared.refresh() }

        engine.openSettings = { [weak self] page in self?.showSettings(page) }
        engine.onStateChange = { [weak self] state in self?.reflect(state) }
        engine.onInventoryChange = { [weak self] in self?.updateStatusIcon() }

        let dictates = AppHotkey.dictate.install(settings.shortcut)
        let translates = AppHotkey.translate.install(settings.translateShortcut)
        let ready = settings.speechReady && Permissions.microphone == .authorized && Permissions.accessibility
        if !dictates {
            showSettings(.general)
        } else if !translates {
            showSettings(.translate)
        } else if !ready {
            showSettings(.overview)
        }
        engine.recoverAtLaunch()
        updateStatusIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        settings.flushSecrets()
        engine.prepareForQuit()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Settings window

    @objc func openSettings(_ sender: Any?) { showSettings(nil) }

    func showSettings(_ page: Page?) {
        if window == nil { window = SettingsWindowController() }
        window?.show(page)
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StatusIcon.image(.idle, badge: false)
        item.button?.toolTip = "Murmur"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func updateStatusIcon() {
        let appearance: StatusIcon.Appearance
        switch engine.state {
        case .listening: appearance = .listening
        case .arming, .working: appearance = .working
        case .idle: appearance = .idle
        }
        let hasBadge = appearance == .idle && (!engine.recordings.all().isEmpty || engine.lastIssue != nil)
        statusItem?.button?.image = StatusIcon.image(appearance, badge: hasBadge)
    }

    private func reflect(_ state: DictationEngine.State) {
        updateStatusIcon()

        // Reserve Escape only while the recording can still be discarded.
        if state == .listening {
            Hotkeys.shared.register(.cancel, Shortcut(keyCode: UInt32(kVK_Escape), modifiers: 0)) { [weak self] in
                guard let self, self.engine.state == .listening else { return }
                self.engine.pressEscape()
            }
        } else {
            Hotkeys.shared.unregister(.cancel)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let hotkeyOK = Hotkeys.shared.isRegistered(.toggle)
        let micOK = Permissions.microphone == .authorized
        let ready = settings.speechReady && micOK && Permissions.accessibility && hotkeyOK

        let headerTitle: String
        if !hotkeyOK {
            headerTitle = "Shortcut unavailable — click to fix"
        } else if ready {
            headerTitle = "Murmur is ready"
        } else {
            headerTitle = "Murmur needs setting up"
        }
        let header = NSMenuItem(title: headerTitle, action: ready ? nil : #selector(openFirstIncomplete), keyEquivalent: "")
        header.target = ready ? nil : self
        header.isEnabled = !ready
        header.image = NSImage(systemSymbolName: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [ready ? NSColor(Brand.mint) : NSColor(Brand.amber)]))
        menu.addItem(header)

        if let issue = engine.lastIssue {
            menu.addItem(makeIssueItem(issue))
        }
        menu.addItem(.separator())

        let targetLang = TranslatePrompt.language(settings.translateLanguage)
        let targetShort = TranslationLanguages.native(targetLang)

        if engine.state == .listening {
            let translating = engine.intent == .translate
            let stop = NSMenuItem(title: translating ? "Stop and Translate (\(targetShort))" : "Stop and Insert",
                                  action: #selector(dictateFromMenu), keyEquivalent: "")
            stop.target = self
            stop.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil)
            menu.addItem(stop)
        } else {
            let idle = engine.state == .idle
            let dictate = NSMenuItem(title: "Start Dictation", action: #selector(dictateFromMenu), keyEquivalent: "")
            dictate.target = self
            dictate.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
            dictate.toolTip = "Or press \(settings.shortcut.display) anywhere"
            dictate.isEnabled = idle
            menu.addItem(dictate)
            let translate = NSMenuItem(title: "Dictate and Translate (\(targetShort))", action: #selector(translateFromMenu), keyEquivalent: "")
            translate.target = self
            translate.image = NSImage(systemSymbolName: "translate", accessibilityDescription: nil)
            translate.toolTip = "Or press \(settings.translateShortcut.display) anywhere"
            translate.isEnabled = idle
            menu.addItem(translate)
        }
        if engine.state != .idle {
            let cancel = NSMenuItem(title: "Cancel", action: #selector(cancelFromMenu), keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
        }

        // Quick target-language switcher so users don't have to open Settings to flip languages.
        menu.addItem(makeLanguageMenuItem(current: targetLang))

        let shortcuts = NSMenuItem(title: "\(settings.shortcut.display) dictate · \(settings.translateShortcut.display) translate",
                                   action: nil, keyEquivalent: "")
        shortcuts.isEnabled = false
        menu.addItem(shortcuts)
        menu.addItem(.separator())

        if engine.state == .idle { addRecovery(to: menu) }

        let today = UsageStore.shared.summary.today
        let stats = NSMenuItem(title: today.uses == 0 ? "Nothing dictated today"
                               : "Today: \(Format.count(today.characters)) characters · \(Format.minutes(today.minutesSaved)) saved",
                               action: #selector(openOverview), keyEquivalent: "")
        stats.target = self
        stats.image = NSImage(systemSymbolName: "chart.bar", accessibilityDescription: nil)
        menu.addItem(stats)
        menu.addItem(.separator())

        let open = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)
        menu.addItem(NSMenuItem(title: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func makeIssueItem(_ issue: DictationEngine.LastIssue) -> NSMenuItem {
        let item = NSMenuItem(title: "Last issue: \(issue.title)", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [NSColor(Brand.amber)]))
        item.toolTip = issue.detail ?? issue.title

        let sub = NSMenu()
        if let detail = issue.detail, !detail.isEmpty {
            let info = NSMenuItem(title: Self.snippet(detail, limit: 84), action: nil, keyEquivalent: "")
            info.isEnabled = false
            info.toolTip = detail
            sub.addItem(info)
            sub.addItem(.separator())
        }
        if let page = issue.page {
            let open = NSMenuItem(title: "Open \(page.title) Settings…", action: #selector(openIssueSettings(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = page.rawValue
            sub.addItem(open)
        }
        let copy = NSMenuItem(title: "Copy Error Details", action: #selector(copyIssueDetail), keyEquivalent: "")
        copy.target = self
        sub.addItem(copy)
        let dismiss = NSMenuItem(title: "Dismiss", action: #selector(dismissIssue), keyEquivalent: "")
        dismiss.target = self
        sub.addItem(dismiss)
        item.submenu = sub
        return item
    }

    private func makeLanguageMenuItem(current: String) -> NSMenuItem {
        let item = NSMenuItem(title: "Translate Into: \(TranslationLanguages.native(current))", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        let sub = NSMenu()
        let listed = TranslationLanguages.entry(current)
        if listed == nil {
            let custom = NSMenuItem(title: current, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            custom.target = self
            custom.representedObject = current
            custom.state = .on
            sub.addItem(custom)
            sub.addItem(.separator())
        }
        for lang in TranslationLanguages.all {
            let label = lang.native == lang.name ? lang.name : "\(lang.name) — \(lang.native)"
            let entry = NSMenuItem(title: label, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = lang.name
            entry.state = listed?.name == lang.name ? .on : .off
            sub.addItem(entry)
        }
        sub.addItem(.separator())
        let other = NSMenuItem(title: "Custom Language…", action: #selector(openTranslate), keyEquivalent: "")
        other.target = self
        sub.addItem(other)
        item.submenu = sub
        return item
    }

    @objc private func openFirstIncomplete() {
        if !settings.speechReady {
            showSettings(.speech)
        } else if Permissions.microphone != .authorized || !Permissions.accessibility || !Hotkeys.shared.isRegistered(.toggle) {
            showSettings(.general)
        } else if !Hotkeys.shared.isRegistered(.translate) {
            showSettings(.translate)
        } else {
            showSettings(.overview)
        }
    }

    @objc private func openIssueSettings(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let page = Page(rawValue: raw) {
            showSettings(page)
        }
    }

    @objc private func copyIssueDetail() {
        guard let issue = engine.lastIssue else { return }
        let text = issue.detail.map { "\(issue.title): \($0)" } ?? issue.title
        Clipboard.put(text)
        engine.hud.finish(.done("Error details copied"))
    }

    @objc private func dismissIssue() {
        engine.clearLastIssue()
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        settings.translateLanguage = name
    }

    @objc private func openTranslate() { showSettings(.translate) }

    @objc private func dictateFromMenu() { pressFromMenu(.dictate) }

    @objc private func translateFromMenu() { pressFromMenu(.translate) }

    private func pressFromMenu(_ intent: DictationEngine.Intent) {
        // Let the menu close and the previous app regain focus first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { DictationEngine.shared.press(intent) }
    }

    @objc private func cancelFromMenu() { engine.cancel() }

    // MARK: Recovery

    /// Recordings whose words never all came back, and the last transcript
    /// as Doubao heard it, before the model changed it.
    private func addRecovery(to menu: NSMenu) {
        let saved = engine.recordings.all()
        if !saved.isEmpty {
            let header = NSMenuItem(title: saved.count == 1 ? "Not transcribed yet" : "\(saved.count) recordings not transcribed yet",
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            if saved.count == 1, let r = saved.first {
                let item = NSMenuItem(title: "Transcribe Again · \(Self.describe(r))", action: #selector(transcribeAgain(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = r.id
                item.image = NSImage(systemSymbolName: r.translate ? "translate" : "arrow.clockwise", accessibilityDescription: nil)
                item.toolTip = "Transcribes it again\(r.translate ? ", translates it" : "") and inserts the text where you're typing"
                menu.addItem(item)
                let delete = NSMenuItem(title: "Delete Saved Recording…", action: #selector(deleteRecordings), keyEquivalent: "")
                delete.target = self
                menu.addItem(delete)
            } else {
                for r in saved.prefix(5) {
                    let row = NSMenuItem(title: Self.describe(r), action: nil, keyEquivalent: "")
                    row.image = NSImage(systemSymbolName: r.translate ? "translate" : "waveform", accessibilityDescription: nil)
                    let sub = NSMenu()
                    let retry = NSMenuItem(title: "Transcribe Again", action: #selector(transcribeAgain(_:)), keyEquivalent: "")
                    retry.target = self
                    retry.representedObject = r.id
                    retry.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
                    sub.addItem(retry)
                    let del = NSMenuItem(title: "Delete Recording…", action: #selector(deleteOneRecording(_:)), keyEquivalent: "")
                    del.target = self
                    del.representedObject = r.id
                    del.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
                    sub.addItem(del)
                    row.submenu = sub
                    menu.addItem(row)
                }
                let deleteAll = NSMenuItem(title: "Delete All Saved Recordings…", action: #selector(deleteRecordings), keyEquivalent: "")
                deleteAll.target = self
                menu.addItem(deleteAll)
            }
            menu.addItem(.separator())
        }
        if engine.lastResult != nil || engine.lastHeard != nil {
            if let result = engine.lastResult {
                let copy = NSMenuItem(title: "Copy Last Result · \(Self.snippet(result, limit: 28))",
                                      action: #selector(copyLastResult), keyEquivalent: "")
                copy.target = self
                copy.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
                copy.toolTip = Self.snippet(result, limit: 220)
                menu.addItem(copy)
            }
            if let heard = engine.lastHeard, heard != engine.lastResult {
                let copy = NSMenuItem(title: "Copy Last Transcript · \(Self.snippet(heard, limit: 24))",
                                      action: #selector(copyLastHeard), keyEquivalent: "")
                copy.target = self
                copy.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil)
                copy.toolTip = "As Doubao heard it: \(Self.snippet(heard, limit: 220))"
                menu.addItem(copy)
            }
            menu.addItem(.separator())
        }
    }

    private static func snippet(_ text: String, limit: Int) -> String {
        let flat = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(max(1, limit - 1))) + "…"
    }

    private static func describe(_ r: RecordingStore.Recording) -> String {
        "\(DictationEngine.duration(r.seconds)), \(Format.day(r.date)) \(r.date.formatted(date: .omitted, time: .shortened))"
    }

    @objc private func transcribeAgain(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let recording = engine.recordings.all().first(where: { $0.id == id }) else { return }
        // Let the menu close and the previous app regain focus first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { DictationEngine.shared.transcribeAgain(recording) }
    }

    @objc private func deleteOneRecording(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let rec = engine.recordings.all().first(where: { $0.id == id }) else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Delete this saved recording?"
        alert.informativeText = "\(Self.describe(rec)) will be permanently removed."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn, engine.state == .idle else { return }
        engine.recordings.delete(id)
        updateStatusIcon()
    }

    @objc private func deleteRecordings() {
        let saved = engine.recordings.all()
        guard !saved.isEmpty else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = saved.count == 1 ? "Delete the saved recording?" : "Delete \(saved.count) saved recordings?"
        alert.informativeText = "What was said in \(saved.count == 1 ? "it" : "them") can't be transcribed after this."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn, engine.state == .idle else { return }
        saved.forEach { engine.recordings.delete($0.id) }
        updateStatusIcon()
    }

    @objc private func copyLastResult() {
        guard let text = engine.lastResult else { return }
        Clipboard.put(text)
        engine.hud.finish(.done("Copied"))
    }

    @objc private func copyLastHeard() {
        guard let text = engine.lastHeard else { return }
        Clipboard.put(text)
        engine.hud.finish(.done("Transcript copied"))
    }

    @objc private func openOverview() { showSettings(.overview) }
}

// MARK: - Window

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let navigator = Navigator()

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Murmur"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "murmur.settings")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 560)
        window.contentViewController = NSHostingController(rootView: RootView().environment(navigator))
        window.setContentSize(NSSize(width: 920, height: 680))
        window.setFrameAutosaveName("MurmurSettings")
        window.delegate = self
        if !window.setFrameUsingName("MurmurSettings") { window.center() }
    }

    func show(_ page: Page?) {
        if let page { navigator.page = page }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu bar app: no Dock icon, no app switcher entry.
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - Main menu

/// Only what a settings window needs: the edit commands make ⌘C, ⌘V and
/// ⌘A work in the fields.
@MainActor
enum MainMenu {
    static func make(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(NSMenuItem(title: "About Murmur", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        app.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ",")
        settings.target = target
        app.addItem(settings)
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Hide Murmur", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(submenu(app, "Murmur"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        main.addItem(submenu(edit, "Edit"))

        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        main.addItem(submenu(window, "Window"))
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ menu: NSMenu, _ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

// MARK: - Menu bar icon

/// The mark as a menu bar template: coral while listening, violet while
/// transcribing/polishing, with a small amber dot when recordings or an issue wait.
@MainActor
enum StatusIcon {
    enum Appearance: Hashable { case idle, listening, working }
    private struct Key: Hashable { let appearance: Appearance; let badge: Bool }
    private static var cache: [Key: NSImage] = [:]

    static func image(active: Bool) -> NSImage {
        image(active ? .listening : .idle, badge: false)
    }

    static func image(_ appearance: Appearance, badge: Bool = false) -> NSImage {
        let key = Key(appearance: appearance, badge: badge)
        if let cached = cache[key] { return cached }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let heights: [CGFloat] = [0.36, 0.72, 1.0, 0.58, 0.32, 0.32]
            let w: CGFloat = 2
            let gap = (rect.width - 2 - CGFloat(heights.count) * w) / CGFloat(heights.count - 1)
            for (i, h) in heights.enumerated() {
                let height = max(w, h * 13)
                let bar = NSRect(x: 1 + CGFloat(i) * (w + gap), y: (rect.height - height) / 2, width: w, height: height)
                let color: NSColor
                switch appearance {
                case .idle:
                    color = badge ? .labelColor : .black
                case .listening:
                    color = i < 4 ? NSColor(Brand.coral) : .labelColor
                case .working:
                    color = i < 4 ? NSColor(Brand.violet) : .labelColor
                }
                color.setFill()
                NSBezierPath(roundedRect: bar, xRadius: w / 2, yRadius: w / 2).fill()
            }
            if badge {
                let dot = NSRect(x: rect.width - 5, y: rect.height - 5.5, width: 4.5, height: 4.5)
                NSColor(Brand.amber).setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = (appearance == .idle && !badge)
        switch appearance {
        case .listening: image.accessibilityDescription = "Murmur — listening"
        case .working: image.accessibilityDescription = "Murmur — working"
        case .idle: image.accessibilityDescription = badge ? "Murmur — attention needed" : "Murmur"
        }
        cache[key] = image
        return image
    }
}
