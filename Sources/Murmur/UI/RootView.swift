import AVFoundation
import Observation
import SwiftUI

@MainActor @Observable
final class Navigator {
    var page: Page = .overview
}

/// Permissions and shortcut status change outside the view; while the window
/// is open, check every second so the checklist ticks itself off.
@MainActor @Observable
final class Readiness {
    static let shared = Readiness()
    private(set) var microphone = Permissions.microphone
    private(set) var accessibility = Permissions.accessibility
    private(set) var dictateHotkeyOK = Permissions.assumeGranted || Hotkeys.shared.isRegistered(.toggle)
    private(set) var translateHotkeyOK = Permissions.assumeGranted || Hotkeys.shared.isRegistered(.translate)
    @ObservationIgnored private var timer: Timer?

    func refresh() {
        let mic = Permissions.microphone
        let ax = Permissions.accessibility
        let dictOK = Permissions.assumeGranted || Hotkeys.shared.isRegistered(.toggle)
        let transOK = Permissions.assumeGranted || Hotkeys.shared.isRegistered(.translate)
        if mic != microphone { microphone = mic }
        if ax != accessibility {
            accessibility = ax
            if ax, let front = NSWorkspace.shared.frontmostApplication { AccessibilityBooster.shared.boost(front) }
        }
        if dictOK != dictateHotkeyOK { dictateHotkeyOK = dictOK }
        if transOK != translateHotkeyOK { translateHotkeyOK = transOK }
    }

    func watch(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { Readiness.shared.refresh() }
        }
    }

    var micReady: Bool { microphone == .authorized }

    /// Required steps still open: the Doubao key, the microphone, Accessibility.
    var stepsLeft: Int {
        [AppSettings.shared.speechReady, micReady, accessibility].filter { !$0 }.count
    }

    /// First page that still needs setup or attention.
    var firstIncompletePage: Page {
        if !AppSettings.shared.speechReady { return .speech }
        if !micReady || !accessibility || !dictateHotkeyOK { return .general }
        if !translateHotkeyOK { return .translate }
        return .overview
    }
}

extension Page {
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .speech: return "Speech"
        case .polish: return "Polish"
        case .translate: return "Translate"
        case .general: return "General"
        }
    }

    /// Flat, bare glyphs for the sidebar: one weight, one color.
    var symbol: String {
        switch self {
        case .overview: return "chart.bar"
        case .speech: return "waveform"
        case .polish: return "sparkles"
        case .translate: return "translate"
        case .general: return "gearshape"
        }
    }

    /// Stage index (1–3) for pipeline pages, nil for Overview and General.
    var pipelineStep: Int? {
        switch self {
        case .speech: return 1
        case .polish: return 2
        case .translate: return 3
        case .overview, .general: return nil
        }
    }

    var tintColor: Color {
        switch self {
        case .speech: return Brand.coral
        case .polish: return Brand.violet
        case .translate: return Color(hex: 0x3DD6C0)
        case .overview, .general: return Color.accentColor
        }
    }
}

struct RootView: View {
    @Environment(Navigator.self) private var navigator

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 208, max: 240)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            Detail()
        }
        .background {
            // ⌘1 – ⌘5 switch settings pages from anywhere in the window.
            ForEach(Array(Page.allCases.enumerated()), id: \.element.id) { index, page in
                let key = KeyEquivalent(Character(String(index + 1)))
                Button("") { withAnimation(Motion.snappy) { navigator.page = page } }
                    .keyboardShortcut(key, modifiers: .command)
                    .focusable(false)
                    .focusEffectDisabled()
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .onAppear { Readiness.shared.watch(true) }
        .onDisappear { Readiness.shared.watch(false) }
    }
}

/// The page on the right. Its own view, so it is the one that observes the
/// navigator and redraws when the page changes.
private struct Detail: View {
    @Environment(Navigator.self) private var navigator

    var body: some View {
        let page = navigator.page
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                switch page {
                case .overview: OverviewPage()
                case .speech: SpeechPage()
                case .polish: PolishPage()
                case .translate: TranslatePage()
                case .general: GeneralPage()
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 22)
            .padding(.bottom, 40)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
            .id(page)
            .transition(.opacity.combined(with: .offset(y: 6)))
        }
        .animation(.easeOut(duration: 0.22), value: page)
    }
}

// MARK: - Sidebar

/// Overview at top, the 3-stage Speech → Polish → Translate pipeline connected
/// visually in the middle, and General below.
private struct Sidebar: View {
    @Environment(Navigator.self) private var navigator
    @Namespace private var highlight
    private let settings = AppSettings.shared
    private let readiness = Readiness.shared

    private static let pipelinePages: [Page] = [.speech, .polish, .translate]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                row(.overview)

                Text("PIPELINE")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.7)
                    .padding(.horizontal, 12)
                    .padding(.top, 14)
                    .padding(.bottom, 4)

                // Connected 1 → 2 → 3 pipeline rail behind the three stages.
                VStack(spacing: 3) {
                    ForEach(Self.pipelinePages) { page in
                        row(page)
                    }
                }
                .background(alignment: .topLeading) {
                    // Two short vertical connectors centered cleanly between
                    // circle 1 (y=17), circle 2 (y=54), and circle 3 (y=91).
                    VStack(spacing: 23) {
                        Capsule()
                            .fill(LinearGradient(
                                colors: [Brand.coral.opacity(0.55), Brand.violet.opacity(0.55)],
                                startPoint: .top, endPoint: .bottom
                            ))
                            .frame(width: 1.5, height: 14)
                        Capsule()
                            .fill(LinearGradient(
                                colors: [Brand.violet.opacity(0.55), Color(hex: 0x3DD6C0).opacity(0.55)],
                                startPoint: .top, endPoint: .bottom
                            ))
                            .frame(width: 1.5, height: 14)
                    }
                    .padding(.top, 28.5)
                    .padding(.leading, 19.25)
                }

                Rectangle()
                    .fill(Color.hairline)
                    .frame(height: 0.5)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)

                row(.general)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            Spacer(minLength: 12)
            SidebarFooter {
                withAnimation(Motion.snappy) { navigator.page = readiness.firstIncompletePage }
            }
        }
        .frame(minWidth: 190, idealWidth: 208, maxWidth: .infinity, alignment: .leading)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.upArrow) { step(-1) }
    }

    private func row(_ page: Page) -> some View {
        SidebarRow(page: page, selected: navigator.page == page,
                   needsAttention: needsAttention(page), highlight: highlight) {
            withAnimation(Motion.snappy) { navigator.page = page }
        }
    }

    private func step(_ by: Int) -> KeyPress.Result {
        let all = Page.allCases
        guard let i = all.firstIndex(of: navigator.page) else { return .ignored }
        let next = all.index(i, offsetBy: by, limitedBy: by > 0 ? all.index(before: all.endIndex) : all.startIndex) ?? i
        withAnimation(Motion.snappy) { navigator.page = all[next] }
        return .handled
    }

    private func needsAttention(_ page: Page) -> Bool {
        switch page {
        case .overview, .polish: return false
        case .speech: return !settings.speechReady
        case .translate: return !readiness.translateHotkeyOK
        case .general: return !readiness.micReady || !readiness.accessibility || !readiness.dictateHotkeyOK
        }
    }
}

private struct SidebarRow: View {
    let page: Page
    let selected: Bool
    let needsAttention: Bool
    let highlight: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let step = page.pipelineStep {
                    Text("\(step)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(selected ? .white : page.tintColor)
                        .frame(width: 17, height: 17)
                        .background(
                            Circle().fill(selected ? page.tintColor : page.tintColor.opacity(0.11))
                        )
                        .overlay(
                            Circle().strokeBorder(selected ? Color.clear : page.tintColor.opacity(0.45), lineWidth: 1)
                        )
                        .frame(width: 20)
                } else {
                    Image(systemName: page.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(selected ? page.tintColor : Color(nsColor: .secondaryLabelColor))
                        .frame(width: 20)
                }
                Text(page.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(Color(nsColor: selected ? .labelColor : .secondaryLabelColor))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 4)
                if needsAttention {
                    Circle()
                        .fill(Brand.amber)
                        .frame(width: 6, height: 6)
                        .help("Needs attention")
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.075))
                        .matchedGeometryEffect(id: "selection", in: highlight)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.035))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.gentle, value: hovering)
        .animation(Motion.smooth, value: needsAttention)
        .accessibilityLabel(page.pipelineStep.map { "Step \($0): \(page.title)" } ?? page.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One line at the foot: whether Murmur is ready, and its shortcut.
private struct SidebarFooter: View {
    let showSetup: () -> Void
    private let settings = AppSettings.shared
    private let readiness = Readiness.shared

    var body: some View {
        let left = readiness.stepsLeft
        let hotkeyIssue = left == 0 && !readiness.dictateHotkeyOK
        VStack(spacing: 0) {
            Rectangle().fill(Color.hairline).frame(height: 0.5)
            HStack(spacing: 8) {
                Circle()
                    .fill(left == 0 && !hotkeyIssue ? Brand.mint : Brand.amber)
                    .frame(width: 7, height: 7)
                Group {
                    if left == 0 && !hotkeyIssue {
                        Text("Ready")
                    } else if hotkeyIssue {
                        Button("Shortcut issue", action: showSetup)
                            .buttonStyle(.plain)
                            .help("Open General to pick another shortcut")
                    } else {
                        Button(left == 1 ? "1 step left" : "\(left) steps left", action: showSetup)
                            .buttonStyle(.plain)
                            .help("Jump to the next setup step")
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText())
                Spacer(minLength: 6)
                KeyCaps(caps: settings.shortcut.caps, size: 18)
                    .help("Press anywhere to dictate")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
        }
        .animation(Motion.gentle, value: left)
    }
}
