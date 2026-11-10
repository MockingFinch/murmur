import Charts
import MurmurCore
import SwiftUI

struct OverviewPage: View {
    @Environment(Navigator.self) private var navigator
    private let settings = AppSettings.shared
    private let readiness = Readiness.shared
    private let store = UsageStore.shared
    @State private var confirmReset = false

    var body: some View {
        let summary = store.summary
        Hero(shortcut: settings.shortcut)

        if !setupComplete {
            PageSection(title: "Get set up") {
                Card(padding: 6) { checklist }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }

        PageSection(title: "Today") {
            HStack(spacing: 12) {
                StatTile(value: Format.count(summary.today.characters), label: "characters",
                         symbol: "character.cursor.ibeam", tint: Brand.azure)
                StatTile(value: Format.minutes(summary.today.minutesSaved), label: "saved against typing",
                         symbol: "hourglass", tint: Brand.mint)
                StatTile(value: Format.count(summary.today.uses), label: summary.today.uses == 1 ? "use" : "uses",
                         symbol: "waveform", tint: Brand.coral)
            }
        }

        PageSection(title: "Last 14 days") {
            Card { ActivityChart(days: summary.days) }
        }

        PageSection(title: "All time", trailing: summary.allTime.uses > 0 ? AnyView(resetButton) : nil) {
            Card(padding: 4) {
                let all = summary.allTime
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        Figure(title: "Characters", value: Format.count(all.characters))
                        Figure(title: "Time saved", value: Format.minutes(all.minutesSaved))
                        Figure(title: "Spoken", value: Format.minutes(all.audioSeconds / 60))
                        Figure(title: "Day streak", value: summary.streak == 0 ? "—" : "\(summary.streak)")
                    }
                    Divider().gridCellUnsizedAxes(.horizontal).padding(.horizontal, 14).opacity(0.6)
                    GridRow {
                        Figure(title: "Dictations", value: Format.count(all.dictations))
                        Figure(title: "Refines", value: Format.count(all.refines))
                        Figure(title: "Polished", value: summary.polishRate.map { Format.percent($0) } ?? "—",
                               help: "Of the times the model was asked, how often its text went in.")
                        Figure(title: "Wait after stop", value: summary.medianWait.map { Format.seconds($0) } ?? "—",
                               help: "Median time from your second press to the text appearing (last 50 uses).")
                    }
                }
            }
        }

        HStack(spacing: 7) {
            Image(systemName: "lock.fill").font(.system(size: 10))
            Text("Statistics are measures only. Murmur never stores what you said or wrote.")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 4)
        .confirmationDialog("Reset all statistics?", isPresented: $confirmReset) {
            Button("Reset Statistics", role: .destructive) { withAnimation(Motion.smooth) { store.reset() } }
        } message: {
            Text("This clears every count and the chart. It can't be undone.")
        }
    }

    private var resetButton: some View {
        Button("Reset…") { confirmReset = true }
            .buttonStyle(.link)
            .font(.system(size: 12))
    }

    private var setupComplete: Bool {
        settings.speechReady && readiness.micReady && readiness.accessibility
    }

    @ViewBuilder private var checklist: some View {
        ChecklistRow(done: settings.speechReady, title: "Add your Doubao key",
                     detail: "Murmur listens through Doubao's streaming recognition.") { navigator.page = .speech }
        RowDivider().padding(.vertical, -6)
        ChecklistRow(done: readiness.micReady, title: "Allow the microphone",
                     detail: "Asked the first time you dictate, or set it now.") { navigator.page = .shortcut }
        RowDivider().padding(.vertical, -6)
        ChecklistRow(done: readiness.accessibility, title: "Allow Accessibility",
                     detail: "To read your selection and type the text where your cursor is.") { navigator.page = .shortcut }
        RowDivider().padding(.vertical, -6)
        ChecklistRow(done: settings.polishReady, optional: true, title: "Connect a language model",
                     detail: "Without it, the transcript goes in as Doubao heard it.") { navigator.page = .polish }
    }
}

// MARK: - Hero

/// The one thing to know: press, speak, press.
private struct Hero: View {
    let shortcut: Shortcut

    var body: some View {
        HStack(alignment: .center, spacing: 26) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    KeyCaps(caps: shortcut.caps, size: 34)
                        .environment(\.colorScheme, .light)
                        .animation(Motion.snappy, value: shortcut)
                    Text("anywhere")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Press to talk. Press again to insert.")
                        .font(.system(size: 21, weight: .bold))
                        .tracking(-0.3)
                        .foregroundStyle(.white)
                    Text("Select text first and the same shortcut rewrites it with your prompt instead. The result is also left on your clipboard.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            HeroWave()
                .frame(width: 150, height: 70)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 24)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Brand.ink)
                RadialGradient(colors: [Brand.rose.opacity(0.38), .clear], center: .init(x: 0.92, y: 0.15), startRadius: 0, endRadius: 260)
                RadialGradient(colors: [Brand.violet.opacity(0.3), .clear], center: .init(x: 0.05, y: 1.1), startRadius: 0, endRadius: 300)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: Color(hex: 0x14152A, opacity: 0.25), radius: 14, y: 6)
    }
}

/// The mark, alive: a voice on the left settling into a line of text.
private struct HeroWave: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            Canvas { gc, size in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let bars = 15
                let w: CGFloat = 4
                let gap = (size.width - CGFloat(bars) * w) / CGFloat(bars - 1)
                for i in 0 ..< bars {
                    let x = Double(i) / Double(bars - 1)
                    // Loud on the left, calm on the right.
                    let voice = max(0, 1 - x * 1.35)
                    let wobble = 0.5 + 0.5 * sin(t * 4.1 + Double(i) * 0.9) * cos(t * 1.7 - Double(i) * 0.4)
                    let h = 0.12 + voice * (0.3 + 0.58 * wobble)
                    let height = max(w, CGFloat(h) * size.height)
                    let rect = CGRect(x: CGFloat(i) * (w + gap), y: (size.height - height) / 2, width: w, height: height)
                    let shading: GraphicsContext.Shading = voice > 0.05
                        ? .linearGradient(Gradient(colors: [Color(hex: 0xFF8A5B), Brand.rose]),
                                          startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY))
                        : .color(.white.opacity(0.85))
                    gc.fill(Path(roundedRect: rect, cornerRadius: w / 2), with: shading)
                }
            }
        }
    }
}

// MARK: - Pieces

private struct ChecklistRow: View {
    let done: Bool
    var optional = false
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().strokeBorder(Color.hairline, lineWidth: 1.5).opacity(done ? 0 : 1)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Brand.mint)
                        .scaleEffect(done ? 1 : 0.4)
                        .opacity(done ? 1 : 0)
                }
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 13, weight: .medium))
                            .strikethrough(done, color: .secondary)
                            .foregroundStyle(done ? .secondary : .primary)
                        if optional { Badge(text: "Optional") }
                    }
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                if !done {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: done)
    }
}

private struct StatTile: View {
    let value: String
    let label: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(tint.opacity(0.13)))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cardStroke, lineWidth: 0.5))
        .animation(Motion.smooth, value: value)
    }
}

private struct Figure: View {
    let title: String
    let value: String
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help ?? "")
    }
}

/// Characters a day; the hovered day says exactly how much.
private struct ActivityChart: View {
    let days: [UsageSummary.Day]
    @State private var hovered: Date?

    var body: some View {
        let peak = days.map(\.characters).max() ?? 0
        let focus = days.first { $0.date == hovered } ?? days.last
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let focus {
                    Text(Format.count(focus.characters))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("characters · \(focus.uses) \(focus.uses == 1 ? "use" : "uses")")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Format.day(focus.date))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .animation(Motion.snappy, value: focus?.date)

            Chart(days) { day in
                BarMark(x: .value("Day", day.date, unit: .day),
                        y: .value("Characters", peak == 0 ? 0 : day.characters),
                        width: .ratio(0.62))
                    .cornerRadius(4)
                    .foregroundStyle(day.date == focus?.date ? AnyShapeStyle(Brand.voice) : AnyShapeStyle(Color.primary.opacity(0.13)))
            }
            .chartYScale(domain: 0 ... max(peak, 1) * 11 / 10)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                    AxisValueLabel(format: .dateTime.day(), centered: true)
                        .font(.system(size: 10))
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                guard let frame = proxy.plotFrame else { return }
                                let x = point.x - geo[frame].origin.x
                                if let date: Date = proxy.value(atX: x) {
                                    let day = Calendar.current.startOfDay(for: date.addingTimeInterval(43_200))
                                    hovered = days.contains { $0.date == day } ? day : nil
                                }
                            case .ended:
                                hovered = nil
                            }
                        }
                }
            }
            .frame(height: 130)
            .overlay {
                if peak == 0 {
                    Text("Your first dictation will show up here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Formatting

enum Format {
    static func count(_ n: Int) -> String {
        n.formatted(.number.notation(n >= 100_000 ? .compactName : .automatic))
    }

    static func minutes(_ m: Double) -> String {
        if m < 1 { return m <= 0 ? "0 min" : "<1 min" }
        let total = Int(m.rounded())
        if total < 60 { return "\(total) min" }
        let h = total / 60, rest = total % 60
        return rest == 0 ? "\(h) h" : "\(h) h \(rest) min"
    }

    static func seconds(_ s: Double) -> String {
        s < 10 ? String(format: "%.1f s", s) : "\(Int(s.rounded())) s"
    }

    static func percent(_ p: Double) -> String { "\(Int((p * 100).rounded()))%" }

    static func day(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}
