import AppKit
import AVFoundation
import MurmurCore
import SwiftUI

struct ShortcutPage: View {
    @Bindable private var settings = AppSettings.shared
    private let readiness = Readiness.shared
    @State private var loginItem = Permissions.launchAtLogin
    @State private var askedForAccessibility = false

    var body: some View {
        PageHeader(symbol: "command", gradient: Brand.graphite, title: "Shortcut",
                   subtitle: "Press to start, press again to insert; with text selected, it refines the selection. Translation has its own shortcut, on the Translate page.")

        PageSection(title: "Shortcut") {
            Card { ShortcutRecorder(hotkey: .dictate) }
        }

        PageSection(title: "Permissions") {
            Card {
                PermissionRow(symbol: "mic.fill", title: "Microphone",
                              detail: "To hear you while you dictate. Murmur records only between your two presses.",
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

        PageSection(title: "General") {
            Card {
                SettingRow(title: "Sounds", detail: "A soft cue when listening starts and stops.") {
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

/// Click, press the new combination. Esc gives up; the old one stays.
/// Records either of Murmur's shortcuts; they can't be the same.
struct ShortcutRecorder: View {
    let hotkey: AppHotkey
    @State private var recording = false
    @State private var held: NSEvent.ModifierFlags = []
    @State private var message: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Button { recording ? stop() : start() } label: {
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

            HStack(spacing: 18) {
                if hotkey == .dictate {
                    Hint(caps: hotkey.shortcut.caps, text: "start · stop and insert")
                    Hint(symbol: "text.cursor", text: "select text first to refine it")
                } else {
                    Hint(caps: hotkey.shortcut.caps, text: "start · stop and translate")
                    Hint(symbol: "text.cursor", text: "select text first to translate it")
                }
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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
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
                message = "Add ⌃, ⌥ or ⌘, so the key still types normally on its own."
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            Self.reinstall()
        }
    }

    private func apply(_ candidate: Shortcut) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        defer { Self.reinstall() }
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
