import AppKit
import AVFoundation
import MurmurCore
import SwiftUI

struct GeneralPage: View {
    @Environment(Navigator.self) private var navigator
    @Bindable private var settings = AppSettings.shared
    private let readiness = Readiness.shared
    @State private var loginItem = Permissions.launchAtLogin
    @State private var askedForAccessibility = false

    var body: some View {
        PageHeader(symbol: "gearshape", gradient: Brand.graphite, title: "General",
                   subtitle: "Shortcuts, permissions, floating bar placement, and clipboard behavior.")

        PageSection(title: "Shortcuts") {
            Card {
                ShortcutRecorder(hotkey: .dictate)
                RowDivider()
                SettingRow(title: "Dictate and translate",
                           detail: "Translates speech or selected text into \(TranslationLanguages.native(TranslatePrompt.language(settings.translateLanguage))).") {
                    HStack(spacing: 10) {
                        KeyCaps(caps: settings.translateShortcut.caps, size: 22)
                        Button("Change…") { withAnimation(Motion.snappy) { navigator.page = .translate } }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                    }
                }
            }
        }

        PageSection(title: "Permissions") {
            Card {
                PermissionRow(symbol: "mic.fill", title: "Microphone",
                              detail: "To hear you while you dictate.",
                              granted: readiness.micReady,
                              actionTitle: readiness.microphone == .notDetermined ? "Allow" : "Open Settings") {
                    if readiness.microphone == .notDetermined {
                        Task { _ = await Permissions.requestMicrophone(); readiness.refresh() }
                    } else {
                        Permissions.open(.microphone)
                    }
                }
                RowDivider()
                PermissionRow(symbol: "accessibility", title: Permissions.accessibilityName,
                              detail: "To read the text you selected and to paste the result where your cursor is.",
                              granted: readiness.accessibility, actionTitle: "Open Settings") {
                    Permissions.requestAccessibility()
                    Permissions.open(.accessibility)
                    withAnimation(Motion.gentle) { askedForAccessibility = true }
                }
            }
            // macOS keeps an app's switch tied to the exact build it was
            // turned on for. After an update or rebuild the old entry still
            // shows as on, yet doesn't apply, and nothing on screen says so.
            if askedForAccessibility && !readiness.accessibility {
                Text("Murmur already switched on there? That switch belongs to an earlier build of Murmur, so macOS doesn't apply it to this one. Select Murmur in the list, remove it with −, then click Open Settings here again and switch the new entry on.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Brand.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }
        }

        PageSection(title: "Behavior") {
            Card {
                SettingRow(title: "Floating bar position",
                           detail: "Top stays clear of bottom chat boxes in Slack, WeChat, and AI tools.") {
                    Picker("", selection: $settings.hudPosition) {
                        ForEach(HUDPosition.allCases) { pos in
                            Text(pos.title).tag(pos)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 164)
                }
                RowDivider()
                SettingRow(title: "Restore clipboard after pasting",
                           detail: "Keeps whatever you had copied before dictating. If pasting isn't possible, the text stays on your clipboard.") {
                    Toggle("", isOn: $settings.restoreClipboard).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingRow(title: "Sounds", detail: "Soft chimes as dictation starts, hands off, and finishes.") {
                    Toggle("", isOn: $settings.sounds).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingRow(title: "Open at login", detail: "Murmur lives in the menu bar.") {
                    Toggle("", isOn: Binding(get: { loginItem }, set: {
                        Permissions.launchAtLogin = $0
                        loginItem = Permissions.launchAtLogin
                    }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }
        }
    }
}

// MARK: - Recorder

/// Click, press the new combination. Esc or clicking away gives up; the old one stays.
/// Records either of Murmur's shortcuts; they can't be the same.
struct ShortcutRecorder: View {
    let hotkey: AppHotkey
    @State private var recording = false
    @State private var held: NSEvent.ModifierFlags = []
    @State private var message: String?
    @State private var monitor: Any?
    @State private var resignObservers: [NSObjectProtocol] = []
    @State private var stoppedByClickAt = Date.distantPast

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Button {
                    if recording {
                        stop()
                    } else if Date().timeIntervalSince(stoppedByClickAt) > 0.25 {
                        start()
                    }
                } label: {
                    ZStack {
                        if recording {
                            HStack(spacing: 6) {
                                if heldCaps.isEmpty {
                                    Text("Press a combination…")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.secondary)
                                } else {
                                    KeyCaps(caps: heldCaps, size: 30)
                                }
                            }
                            .transition(.opacity)
                        } else {
                            KeyCaps(caps: hotkey.shortcut.caps, size: 30)
                                .transition(.opacity)
                        }
                    }
                    .frame(minWidth: 220, minHeight: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(recording ? Color.accentColor.opacity(0.08) : Color.well)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(recording ? Color.accentColor.opacity(0.75) : Color.hairline,
                                          style: StrokeStyle(lineWidth: recording ? 1.5 : 0.5, dash: recording ? [5, 4] : []))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(Motion.snappy, value: recording)
                .animation(Motion.snappy, value: heldCaps)

                VStack(alignment: .leading, spacing: 6) {
                    Text(recording ? "Press the new shortcut. Esc to keep the current one." : "Click to change.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if hotkey.shortcut != hotkey.defaultShortcut, !recording {
                        Button("Use \(hotkey.defaultShortcut.display)") { apply(hotkey.defaultShortcut) }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                    }
                }
                Spacer(minLength: 0)
            }

            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Brand.coral)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 16) {
                if hotkey == .dictate {
                    Hint(caps: hotkey.shortcut.caps, text: "tap to toggle · hold to talk")
                    Hint(symbol: "text.cursor", text: "select text to refine")
                } else {
                    Hint(caps: hotkey.shortcut.caps, text: "tap to toggle · hold to translate")
                    Hint(symbol: "text.cursor", text: "select text to translate")
                }
                Hint(caps: ["Esc"], text: "cancel")
            }
            .padding(.top, 2)
        }
        .animation(Motion.smooth, value: message)
        .onDisappear { stop() }
    }

    private var heldCaps: [String] {
        Shortcut(keyCode: 0xFFFF, modifiers: Shortcut.carbonModifiers(held)).modifierSymbols
    }

    private func start() {
        message = nil
        held = []
        recording = true
        // While recording, both shortcuts must reach us, not trigger.
        AppHotkey.allCases.forEach { $0.suspend() }
        let center = NotificationCenter.default
        resignObservers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { stop() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { stop() }
            },
        ]
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { event in
            if event.type == .leftMouseDown {
                stoppedByClickAt = Date()
                stop()
                return event
            }
            if event.type == .flagsChanged {
                held = event.modifierFlags.intersection([.command, .option, .control, .shift])
                return nil
            }
            if event.keyCode == 0x35, held.isEmpty { // Esc alone
                stop()
                return nil
            }
            let candidate = Shortcut(keyCode: UInt32(event.keyCode), modifiers: Shortcut.carbonModifiers(event.modifierFlags))
            if candidate.isValid {
                apply(candidate)
            } else {
                NSSound.beep()
                message = "Add ⌃, ⌥ or ⌘ (or press a Function key), so the key still types normally."
            }
            return nil
        }
    }

    private func tearDownMonitors() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for o in resignObservers { NotificationCenter.default.removeObserver(o) }
        resignObservers.removeAll()
    }

    private func stop() {
        tearDownMonitors()
        if recording {
            recording = false
            Self.reinstall()
            Readiness.shared.refresh()
        }
    }

    private func apply(_ candidate: Shortcut) {
        tearDownMonitors()
        recording = false
        defer {
            Self.reinstall()
            Readiness.shared.refresh()
        }
        if candidate == hotkey.other.shortcut {
            message = "\(candidate.display) is already your \(hotkey.other.role) shortcut. Try another."
            return
        }
        if hotkey.install(candidate) {
            hotkey.shortcut = candidate
            message = nil
        } else {
            message = "\(candidate.display) is taken by another app or by macOS. Try another."
        }
    }

    /// Both shortcuts as saved. A failed install leaves that one off until
    /// a working combination is recorded.
    private static func reinstall() {
        for h in AppHotkey.allCases { h.install(h.shortcut) }
    }
}

private struct Hint: View {
    var caps: [String] = []
    var symbol: String? = nil
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            } else {
                KeyCaps(caps: caps, size: 18)
            }
            Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Permissions

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(granted ? Brand.mint : .secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill((granted ? Brand.mint : Color.secondary).opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.mint)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(.glass)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: granted)
    }
}
