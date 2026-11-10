import AppKit
import MurmurCore
import SwiftUI

/// Murmur's two global shortcuts: one dictates, one dictates and
/// translates. Each is installed, or set aside while it's re-recorded.
@MainActor
enum AppHotkey: CaseIterable {
    case dictate, translate

    private var id: Hotkeys.ID { self == .dictate ? .toggle : .translate }
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
        return Hotkeys.shared.register(id, shortcut) { DictationEngine.shared.press(intent) }
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

        let dictates = AppHotkey.dictate.install(settings.shortcut)
        let translates = AppHotkey.translate.install(settings.translateShortcut)
        let ready = settings.speechReady && Permissions.microphone == .authorized && Permissions.accessibility
        if !dictates {
            showSettings(.shortcut)
        } else if !translates {
            showSettings(.translate)
        } else if !ready {
            showSettings(.overview)
        }
        engine.recoverAtLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        item.button?.image = StatusIcon.image(active: false)
        item.button?.toolTip = "Murmur"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func reflect(_ state: DictationEngine.State) {
        statusItem?.button?.image = StatusIcon.image(active: state == .listening)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let ready = settings.speechReady && Permissions.microphone != .denied && Permissions.accessibility

        let header = NSMenuItem(title: ready ? "Murmur is ready" : "Murmur needs setting up", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.image = NSImage(systemSymbolName: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [ready ? NSColor(Brand.mint) : NSColor(Brand.amber)]))
        menu.addItem(header)
        menu.addItem(.separator())

        if engine.state == .listening {
            let translating = engine.intent == .translate
            let stop = NSMenuItem(title: translating ? "Stop and Translate" : "Stop and Insert",
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
            let translate = NSMenuItem(title: "Dictate and Translate", action: #selector(translateFromMenu), keyEquivalent: "")
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
            for r in saved.prefix(5) {
                let item = NSMenuItem(title: "Transcribe Again · \(Self.describe(r))", action: #selector(transcribeAgain(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = r.id
                item.image = NSImage(systemSymbolName: r.translate ? "translate" : "arrow.clockwise", accessibilityDescription: nil)
                item.toolTip = "Transcribes it again\(r.translate ? ", translates it" : "") and inserts the text where you're typing"
                menu.addItem(item)
            }
            let delete = NSMenuItem(title: saved.count == 1 ? "Delete Saved Recording…" : "Delete Saved Recordings…",
                                    action: #selector(deleteRecordings), keyEquivalent: "")
            delete.target = self
            menu.addItem(delete)
            menu.addItem(.separator())
        }
        if engine.lastResult != nil || engine.lastHeard != nil {
            if engine.lastResult != nil {
                let copy = NSMenuItem(title: "Copy Last Result", action: #selector(copyLastResult), keyEquivalent: "")
                copy.target = self
                copy.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
                copy.toolTip = "The text Murmur last inserted"
                menu.addItem(copy)
            }
            if let heard = engine.lastHeard, heard != engine.lastResult {
                let copy = NSMenuItem(title: "Copy Last Transcript, as Heard", action: #selector(copyLastHeard), keyEquivalent: "")
                copy.target = self
                copy.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil)
                copy.toolTip = "What Doubao heard in the last dictation, before polishing or translating"
                menu.addItem(copy)
            }
            menu.addItem(.separator())
        }
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

/// The mark as a menu bar template: bars that turn coral while listening.
@MainActor
enum StatusIcon {
    private static var cache: [Bool: NSImage] = [:]

    static func image(active: Bool) -> NSImage {
        if let cached = cache[active] { return cached }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let heights: [CGFloat] = [0.36, 0.72, 1.0, 0.58, 0.32, 0.32]
            let w: CGFloat = 2
            let gap = (rect.width - 2 - CGFloat(heights.count) * w) / CGFloat(heights.count - 1)
            for (i, h) in heights.enumerated() {
                let height = max(w, h * 13)
                let bar = NSRect(x: 1 + CGFloat(i) * (w + gap), y: (rect.height - height) / 2, width: w, height: height)
                let color: NSColor = active ? (i < 4 ? NSColor(Brand.coral) : .labelColor) : .black
                color.setFill()
                NSBezierPath(roundedRect: bar, xRadius: w / 2, yRadius: w / 2).fill()
            }
            return true
        }
        image.isTemplate = !active
        image.accessibilityDescription = active ? "Murmur — listening" : "Murmur"
        cache[active] = image
        return image
    }
}
