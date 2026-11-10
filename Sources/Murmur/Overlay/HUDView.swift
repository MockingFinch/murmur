import SwiftUI
import MurmurCore

/// The floating capsule. One shape that reshapes itself through a session:
/// a pill while listening, taller once words appear, narrow to say "done".
struct HUDView: View {
    let model: HUDModel
    var snapshot = false

    static let canvas = CGSize(width: 680, height: 260)

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let mode = model.mode {
                HUDCapsule(model: model, mode: mode, snapshot: snapshot)
                    .transition(HUDTransition())
            }
        }
        .padding(.bottom, 34)
        .frame(width: Self.canvas.width, height: Self.canvas.height)
        .animation(.spring(response: 0.44, dampingFraction: 0.8), value: model.mode == nil)
        .environment(\.colorScheme, .dark)
    }
}

private struct HUDCapsule: View {
    let model: HUDModel
    let mode: HUDModel.Mode
    let snapshot: Bool

    private var line: (text: String, dim: Bool)? {
        switch mode {
        case .listening, .transcribing:
            return model.liveText.isEmpty ? nil : (model.liveText, false)
        case .model:
            if !model.liveText.isEmpty { return (model.liveText, false) }
            return model.preview.isEmpty ? nil : (model.preview, true)
        default:
            return nil
        }
    }

    /// Wide enough for a comfortable line of text; never wider, whatever is said.
    static let textWidth: CGFloat = 460

    private var width: CGFloat {
        switch mode {
        case .listening:
            guard line == nil else { return Self.textWidth }
            return 214 + (model.target == nil ? 0 : 86) + (model.link == .live ? 0 : 118)
        case .transcribing: return line == nil ? 214 : Self.textWidth
        case .model: return Self.textWidth
        case .done(let title): return CGFloat(min(320, 92 + title.count * 8))
        case .notice(let n): return n.detail == nil ? CGFloat(min(380, 100 + n.title.count * 8)) : 420
        case .cancelled: return 150
        }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 23, style: .continuous) }

    /// Changes worth a spring.
    private var layoutKey: String { "\(kind)|\(line == nil)" }

    private var kind: String {
        switch mode {
        case .listening: return "listening"
        case .transcribing: return "transcribing"
        case .model: return "model"
        case .done: return "done"
        case .notice: return "notice"
        case .cancelled: return "cancelled"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let line {
                Transcript(text: line.text, dim: line.dim)
                    .frame(width: Self.textWidth - 36)
                    .padding(.horizontal, 18)
                    .padding(.top, 13)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
            }
            HStack(spacing: 11) {
                leading
                    .frame(width: 22, height: 22)
                center
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.horizontal, 14)
            // A notice with two lines of detail grows; nothing else does.
            .frame(minHeight: 46)
        }
        .frame(width: width)
        .background(glow)
        .background(surface)
        .clipShape(shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 0.6))
        .shadow(color: .black.opacity(0.32), radius: 22, y: 12)
        .keyframeAnimator(initialValue: CGFloat(0), trigger: model.shakes) { content, x in
            content.offset(x: x)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(-9, duration: 0.06)
                CubicKeyframe(8, duration: 0.07)
                CubicKeyframe(-5, duration: 0.07)
                CubicKeyframe(3, duration: 0.06)
                CubicKeyframe(0, duration: 0.07)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: layoutKey)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: width)
    }

    // MARK: Surface

    @ViewBuilder private var surface: some View {
        if snapshot {
            shape.fill(Color(white: 0.11, opacity: 0.94))
        } else {
            shape.fill(Color.black.opacity(0.38))
                .glassEffect(.regular.tint(Color.black.opacity(0.25)), in: shape)
        }
    }

    /// A light under the glass: warm and following the voice while
    /// listening, cool and breathing while the model works.
    @ViewBuilder private var glow: some View {
        switch mode {
        case .listening:
            TimelineView(.animation) { _ in
                let level = Double(model.level)
                ZStack {
                    Aura(color: Color(hex: 0xFF7A59), strength: 0.18 + level * 0.42)
                        .frame(width: 240, height: 84)
                        .offset(x: -60, y: 30)
                    Aura(color: Brand.rose, strength: 0.12 + level * 0.36)
                        .frame(width: 220, height: 76)
                        .offset(x: 40, y: 32)
                }
            }
        case .model, .transcribing:
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                ZStack {
                    Aura(color: Brand.violet, strength: 0.3 + 0.1 * sin(t * 2.2))
                        .frame(width: 260, height: 90)
                        .offset(x: CGFloat(sin(t * 0.9)) * 70, y: 32)
                    Aura(color: Brand.azure, strength: 0.22 + 0.08 * cos(t * 1.7))
                        .frame(width: 220, height: 80)
                        .offset(x: CGFloat(cos(t * 0.7)) * -60, y: 34)
                }
            }
        case .done:
            Aura(color: Brand.mint, strength: 0.4).frame(width: 220, height: 80).offset(y: 30)
        default:
            Color.clear
        }
    }

    // MARK: Parts

    @ViewBuilder private var leading: some View {
        ZStack {
            switch mode {
            case .listening:
                RecordingDot(model: model).transition(.scale.combined(with: .opacity))
            case .transcribing:
                ArcSpinner().transition(.scale.combined(with: .opacity))
            case .model(let job, _, _):
                Image(systemName: job == .polish || job == .refine ? "sparkles" : "translate")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.polish)
                    .symbolEffect(.pulse, options: .repeating)
                    .contentTransition(.symbolEffect(.replace))
                    .transition(.scale.combined(with: .opacity))
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white, Brand.mint)
                    .symbolEffect(.bounce, options: .nonRepeating, value: kind)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            case .notice(let n):
                Image(systemName: noticeSymbol(n.tone))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(noticeColor(n.tone))
                    .transition(.scale.combined(with: .opacity))
            case .cancelled:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: kind)
    }

    @ViewBuilder private var center: some View {
        switch mode {
        case .listening:
            Waveform(model: model, settling: false)
                .frame(height: 26)
                .transition(.opacity)
        case .transcribing(let retry):
            HStack(spacing: 10) {
                Shimmering(text: retry > 0 ? "Reconnecting · \(retry)" : "Transcribing")
                Waveform(model: model, settling: true).frame(width: 46, height: 18)
            }
            .transition(.blurReplace)
        case .model(let job, let retry, let thinking):
            Shimmering(text: modelLabel(job, retry, thinking))
                .id(modelLabel(job, retry, thinking))
                .transition(.blurReplace)
        case .done(let title):
            Text(title)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .transition(.blurReplace)
        case .notice(let n):
            VStack(alignment: .leading, spacing: 2) {
                Text(n.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                if let detail = n.detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(2)
                }
            }
            .padding(.vertical, n.detail == nil ? 0 : 6)
            .transition(.blurReplace)
        case .cancelled:
            Text("Cancelled")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .transition(.blurReplace)
        }
    }

    @ViewBuilder private var trailing: some View {
        if case .listening = mode {
            HStack(spacing: 8) {
                if model.link != .live { LinkBadge(link: model.link).transition(.blurReplace) }
                if let target = model.target { TargetBadge(language: target) }
                ElapsedLabel(since: model.startedAt, limit: DictationEngine.maxRecording)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.link)
            // The waveform gives way; the time and the language never do.
            .fixedSize()
            .transition(.opacity)
        } else if case .model = mode {
            WaitLabel(since: model.waitingSince)
                .transition(.opacity)
        }
    }

    private func modelLabel(_ job: HUDModel.Job, _ retry: Int, _ thinking: Bool) -> String {
        if retry > 0 { return "Retrying · \(retry) of \(OpenRouterClient.maxAttempts)" }
        if thinking { return "Thinking" }
        switch job {
        case .polish: return "Polishing"
        case .refine: return "Refining selection"
        case .translate(let language): return "Translating to \(language)"
        }
    }

    private func noticeSymbol(_ tone: HUDModel.Notice.Tone) -> String {
        switch tone {
        case .info: return "waveform.slash"
        case .warning: return "exclamationmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private func noticeColor(_ tone: HUDModel.Notice.Tone) -> Color {
        switch tone {
        case .info: return .white.opacity(0.7)
        case .warning: return Brand.amber
        case .error: return Brand.coral
        }
    }
}

// MARK: - Pieces

/// The words so far, as a short teleprompter. It is exactly as tall as the
/// text, from one line up to three, so the capsule grows a line at a time.
/// Past three lines the newest stay at the bottom and older ones slide up
/// and fade out at the top: the capsule never grows further.
private struct Transcript: View {
    let text: String
    let dim: Bool
    @State private var overflowing = false

    static let maxLines: CGFloat = 3
    private static let font = Font.system(size: 13.5, weight: .medium)
    private static let spacing: CGFloat = 2.5
    /// Exactly three lines tall, measured from the font, so no sliver of a
    /// fourth line shows above them.
    private static let maxHeight: CGFloat = {
        let f = NSFont.systemFont(ofSize: 13.5, weight: .medium)
        let line = ceil(f.ascender - f.descender + f.leading)
        return maxLines * line + (maxLines - 1) * spacing
    }()
    /// Only the tail can be seen; laying out more is wasted work.
    private static let keep = 360

    var body: some View {
        let maxHeight = Self.maxHeight
        Text(shown)
            .font(Self.font)
            .lineSpacing(Self.spacing)
            .foregroundStyle(.white.opacity(dim ? 0.42 : 0.94))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: Bool.self) { $0.size.height > maxHeight + 1 } action: { overflowing = $0 }
            // Asked for its ideal height, the frame answers with the text's
            // own height, capped at three lines; offered more room, it takes
            // none of it. Overflow stays pinned to the bottom and is clipped.
            .frame(maxHeight: maxHeight, alignment: .bottom)
            .fixedSize(horizontal: false, vertical: true)
            .clipped()
            .mask {
                LinearGradient(stops: [
                    .init(color: overflowing ? .clear : .black, location: 0),
                    .init(color: .black, location: overflowing ? 0.42 : 0),
                ], startPoint: .top, endPoint: .bottom)
            }
            .animation(.easeOut(duration: 0.2), value: shown)
            .animation(.easeOut(duration: 0.2), value: overflowing)
    }

    private var shown: String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > Self.keep else { return flat }
        // Cut at a space when there is one near, so no word starts broken.
        var tail = flat.suffix(Self.keep)
        if let space = tail.prefix(24).firstIndex(of: " ") { tail = tail[tail.index(after: space)...] }
        return String(tail)
    }
}

/// Says, while you speak, which language the text will go in as.
private struct TargetBadge: View {
    let language: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "translate").font(.system(size: 10, weight: .semibold))
            Text(TranslationLanguages.native(language))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 92, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(.white.opacity(0.82))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.1)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .accessibilityLabel("Translating to \(language)")
    }
}

/// The stream to Doubao isn't live. Either way the recording goes on, so
/// the user can keep talking.
private struct LinkBadge: View {
    let link: HUDModel.Link

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: link == .reconnecting ? "wifi.exclamationmark" : "record.circle")
                .font(.system(size: 10, weight: .semibold))
                .symbolEffect(.pulse, options: .repeating, isActive: link == .reconnecting)
            Text(link == .reconnecting ? "Reconnecting" : "Recording only")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .fixedSize()
        }
        .foregroundStyle(Brand.amber)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Brand.amber.opacity(0.14)))
        .overlay(Capsule().strokeBorder(Brand.amber.opacity(0.28), lineWidth: 0.5))
        .accessibilityLabel(link == .reconnecting ? "Reconnecting to Doubao; keep talking" : "Recording only; Doubao refused")
    }
}

private struct RecordingDot: View {
    let model: HUDModel

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let pulse = (t.truncatingRemainder(dividingBy: 1.4)) / 1.4
            let level = CGFloat(model.level)
            ZStack {
                Circle()
                    .fill(Brand.coral)
                    .frame(width: 10, height: 10)
                    .scaleEffect(1 + pulse * 1.4)
                    .opacity(0.55 * (1 - pulse))
                Circle()
                    .fill(Brand.voice)
                    .frame(width: 10, height: 10)
                    .scaleEffect(1 + level * 0.3)
                    .shadow(color: Brand.coral.opacity(0.9), radius: 3 + level * 5)
            }
        }
    }
}

private struct ArcSpinner: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().stroke(.white.opacity(0.14), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: 0.3 + 0.12 * sin(t * 3))
                    .stroke(.white.opacity(0.92), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(t * 400))
            }
            .frame(width: 15, height: 15)
        }
    }
}

/// A word with light sweeping across it.
private struct Shimmering: View {
    let text: String

    var body: some View {
        let label = Text(text).font(.system(size: 13.5, weight: .semibold, design: .rounded))
        label
            .foregroundStyle(.white.opacity(0.55))
            .overlay {
                TimelineView(.animation) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let phase = (t.truncatingRemainder(dividingBy: 1.8)) / 1.8
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.55)
                            .offset(x: -geo.size.width * 0.55 + phase * geo.size.width * 1.9)
                    }
                }
                .mask(label)
            }
            .fixedSize()
    }
}

/// Time recorded; amber in the last minute before the limit stops it.
private struct ElapsedLabel: View {
    let since: Date
    let limit: TimeInterval

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { ctx in
            let s = max(0, Int(ctx.date.timeIntervalSince(since)))
            let closing = Double(s) >= limit - 60
            Text(String(format: "%d:%02d", s / 60, s % 60))
                .font(.system(size: 12.5, weight: closing ? .semibold : .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(closing ? AnyShapeStyle(Brand.amber) : AnyShapeStyle(.white.opacity(0.6)))
                .contentTransition(.numericText())
                .animation(.snappy, value: s)
        }
    }
}

/// Seconds spent waiting for the model, shown once the wait is long
/// enough to wonder about.
private struct WaitLabel: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { ctx in
            let s = max(0, Int(ctx.date.timeIntervalSince(since)))
            Text("\(s)s")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
                .contentTransition(.numericText())
                .opacity(s >= 5 ? 1 : 0)
                .animation(.snappy, value: s)
        }
    }
}

/// Enters from below, small and blurred; leaves shrinking into a blur.
struct HUDTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .scaleEffect(phase.isIdentity ? 1 : (phase == .willAppear ? 0.8 : 0.9), anchor: .bottom)
            .offset(y: phase == .willAppear ? 18 : 0)
            .blur(radius: phase.isIdentity ? 0 : 10)
            .opacity(phase.isIdentity ? 1 : 0)
    }
}

/// Soft light from a gradient rather than a blur: no filter to render
/// each frame, and the same edge everywhere.
private struct Aura: View {
    let color: Color
    let strength: Double

    var body: some View {
        EllipticalGradient(stops: [
            .init(color: color.opacity(strength), location: 0),
            .init(color: color.opacity(strength * 0.45), location: 0.4),
            .init(color: color.opacity(0), location: 1),
        ])
    }
}
