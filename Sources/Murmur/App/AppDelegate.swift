import AppKit
import MurmurCore
import SwiftUI

/// The dictation shortcut, installed or set aside (while it's being re-recorded).
@MainActor
enum ToggleHotkey {
    @discardableResult
    static func install(_ shortcut: Shortcut) -> Bool {
        Hotkeys.shared.register(.toggle, shortcut) { DictationEngine.shared.toggle() }
    }

    static func suspend() { Hotkeys.shared.unregister(.toggle) }
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

        let installed = ToggleHotkey.install(settings.shortcut)
        let ready = settings.speechReady && Permissions.microphone == .authorized && Permissions.accessibility
        if !installed {
            showSettings(.shortcut)
        } else if !ready {
            showSettings(.overview)
        }
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

        let listening = engine.state == .listening
        let toggle = NSMenuItem(title: listening ? "Stop and Insert" : "Start Dictation", action: #selector(toggleFromMenu), keyEquivalent: "")
        toggle.target = self
        toggle.image = NSImage(systemSymbolName: listening ? "stop.circle" : "mic", accessibilityDescription: nil)
        toggle.toolTip = "Or press \(settings.shortcut.display) anywhere"
        toggle.isEnabled = engine.state == .idle || listening
        menu.addItem(toggle)
        if engine.state != .idle {
            let cancel = NSMenuItem(title: "Cancel", action: #selector(cancelFromMenu), keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
        }

        let shortcut = NSMenuItem(title: "Shortcut: \(settings.shortcut.display)", action: nil, keyEquivalent: "")
        shortcut.isEnabled = false
        menu.addItem(shortcut)
        menu.addItem(.separator())

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

    @objc private func toggleFromMenu() {
        // Let the menu close and the previous app regain focus first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { DictationEngine.shared.toggle() }
    }

    @objc private func cancelFromMenu() { engine.cancel() }

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
