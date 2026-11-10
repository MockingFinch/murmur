import AVFoundation
import Observation
import SwiftUI

@MainActor @Observable
final class Navigator {
    var page: Page = .overview
}

/// Permissions change outside the app; while the window is open, look again
/// every second so the checklist ticks itself off.
@MainActor @Observable
final class Readiness {
    static let shared = Readiness()
    private(set) var microphone = Permissions.microphone
    private(set) var accessibility = Permissions.accessibility
    @ObservationIgnored private var timer: Timer?

    func refresh() {
        let mic = Permissions.microphone
        let ax = Permissions.accessibility
        if mic != microphone { microphone = mic }
        if ax != accessibility {
            accessibility = ax
            if ax, let front = NSWorkspace.shared.frontmostApplication { AccessibilityBooster.shared.boost(front) }
        }
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
}

extension Page {
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .speech: return "Speech"
        case .polish: return "Polish"
        case .shortcut: return "Shortcut"
        }
    }

    /// Flat, bare glyphs for the sidebar: one weight, one color.
    var symbol: String {
        switch self {
        case .overview: return "chart.bar"
        case .speech: return "waveform"
        case .polish: return "sparkles"
        case .shortcut: return "command"
        }
    }
}

struct RootView: View {
    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 208, max: 240)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            Detail()
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
            VStack(alignment: .leading, spacing: 28) {
                switch page {
                case .overview: OverviewPage()
                case .speech: SpeechPage()
                case .polish: PolishPage()
                case .shortcut: ShortcutPage()
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

/// Four quiet rows with room to breathe. The highlight is a soft fill that
/// glides to the chosen row; a small amber dot marks a page that still
/// needs setting up.
private struct Sidebar: View {
    @Environment(Navigator.self) private var navigator
    @Namespace private var highlight
    private let settings = AppSettings.shared
    private let readiness = Readiness.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 3) {
                ForEach(Page.allCases) { page in
                    SidebarRow(page: page, selected: navigator.page == page,
                               needsAttention: needsAttention(page), highlight: highlight) {
                        withAnimation(Motion.snappy) { navigator.page = page }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            Spacer(minLength: 12)
            SidebarFooter { withAnimation(Motion.snappy) { navigator.page = .overview } }
        }
        .frame(minWidth: 190, idealWidth: 208, maxWidth: .infinity, alignment: .leading)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.upArrow) { step(-1) }
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
        case .shortcut: return !readiness.micReady || !readiness.accessibility
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
            HStack(spacing: 11) {
                Image(systemName: page.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(selected ? Color.accentColor : Color(nsColor: .secondaryLabelColor))
                    .frame(width: 20)
                Text(page.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(nsColor: selected ? .labelColor : .secondaryLabelColor))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 4)
                if needsAttention {
                    Circle()
                        .fill(Brand.amber)
                        .frame(width: 6, height: 6)
                        .help("Needs setting up")
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
        .accessibilityLabel(page.title)
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
        VStack(spacing: 0) {
            Rectangle().fill(Color.hairline).frame(height: 0.5)
            HStack(spacing: 8) {
                Circle()
                    .fill(left == 0 ? Brand.mint : Brand.amber)
                    .frame(width: 7, height: 7)
                Group {
                    if left == 0 {
                        Text("Ready")
                    } else {
                        Button(left == 1 ? "1 step left" : "\(left) steps left", action: showSetup)
                            .buttonStyle(.plain)
                            .help("Show what's left to set up")
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
