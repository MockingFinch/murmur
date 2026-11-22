import MurmurCore
import SwiftUI

/// Visualizes Murmur's 3-stage chained pipeline (Speech → Polish → Translate)
/// on the Overview page. Each stage card is clickable to jump directly to its
/// configuration page, and shows live status so users see how the stages chain.
struct PipelineFlowCard: View {
    @Environment(Navigator.self) private var navigator
    private let settings = AppSettings.shared

    private var targetLanguage: String {
        TranslationLanguages.native(TranslatePrompt.language(settings.translateLanguage))
    }

    private var modelShortName: String {
        let raw = settings.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "Not set" }
        return raw.split(separator: "/").last.map(String.init) ?? raw
    }

    private var speechSubdetail: String {
        let terms = settings.vocabularyTerms.count
        if !settings.speechReady { return "Add Doubao key" }
        return terms > 0 ? "Ready · \(terms) custom \(terms == 1 ? "term" : "terms")" : "Live streaming · 2nd pass"
    }

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    StageNode(
                        step: 1,
                        title: "Speech",
                        symbol: "waveform",
                        gradient: Brand.voice,
                        accent: Brand.coral,
                        value: settings.speechReady ? "Doubao ASR 2.0" : "Not connected",
                        detail: speechSubdetail,
                        health: settings.speechReady ? .ok : .attention
                    ) {
                        withAnimation(Motion.snappy) { navigator.page = .speech }
                    }

                    FlowArrow(active: settings.speechReady, from: Brand.coral, to: Brand.violet)

                    StageNode(
                        step: 2,
                        title: "Polish",
                        symbol: "sparkles",
                        gradient: Brand.polish,
                        accent: Brand.violet,
                        value: settings.polishReady ? modelShortName : "Skipped (raw text)",
                        detail: settings.polishReady ? "Cleans fillers & self-corrections" : "Optional — connect a model",
                        health: settings.polishReady ? .ok : .idle
                    ) {
                        withAnimation(Motion.snappy) { navigator.page = .polish }
                    }

                    FlowArrow(active: settings.polishReady, from: Brand.violet, to: Color(hex: 0x3DD6C0))

                    StageNode(
                        step: 3,
                        title: "Translate",
                        symbol: "translate",
                        gradient: Brand.translate,
                        accent: Color(hex: 0x3DD6C0),
                        value: settings.polishReady ? "Into \(targetLanguage)" : "Needs Polish model",
                        detail: "Runs on Polish's clean output",
                        health: settings.polishReady ? .ok : .idle
                    ) {
                        withAnimation(Motion.snappy) { navigator.page = .translate }
                    }
                }

                Rectangle().fill(Color.hairline).frame(height: 0.5)

                HStack(spacing: 14) {
                    RouteLegend(caps: settings.shortcut.caps,
                                stages: settings.polishReady ? "Speech → Polish" : "Speech only",
                                tint: Brand.violet)
                    RouteLegend(caps: settings.translateShortcut.caps,
                                stages: "Speech → Polish → \(targetLanguage)",
                                tint: Color(hex: 0x3DD6C0))
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private struct StageNode: View {
        let step: Int
        let title: String
        let symbol: String
        let gradient: LinearGradient
        let accent: Color
        let value: String
        let detail: String
        let health: Health
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        GlyphTile(symbol: symbol, gradient: gradient, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text("STEP \(step)")
                                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(accent)
                                    .tracking(0.4)
                                Circle()
                                    .fill(health.color)
                                    .frame(width: 5.5, height: 5.5)
                            }
                            Text(title)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        Spacer(minLength: 0)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(value)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary.opacity(health == .idle ? 0.6 : 0.92))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(hovering ? accent.opacity(0.08) : Color.well)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(hovering ? accent.opacity(0.35) : Color.hairline, lineWidth: hovering ? 1 : 0.5)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.gentle, value: hovering)
        }
    }

    private struct FlowArrow: View {
        let active: Bool
        let from: Color
        let to: Color

        var body: some View {
            Image(systemName: "arrow.right")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(active
                                 ? AnyShapeStyle(LinearGradient(colors: [from, to], startPoint: .leading, endPoint: .trailing))
                                 : AnyShapeStyle(Color.secondary.opacity(0.35)))
                .frame(width: 14)
        }
    }

    private struct RouteLegend: View {
        let caps: [String]
        let stages: String
        let tint: Color

        var body: some View {
            HStack(spacing: 6) {
                KeyCaps(caps: caps, size: 17)
                Text(stages)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Compact clickable breadcrumb placed under the header of Speech, Polish, and
/// Translate pages so users always see where that stage sits in the chain.
struct StageBreadcrumb: View {
    let current: HUDModel.Stage
    @Environment(Navigator.self) private var navigator
    private let settings = AppSettings.shared

    private var targetLanguage: String {
        TranslationLanguages.native(TranslatePrompt.language(settings.translateLanguage))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                pill(step: 1, stage: .speech, title: "Speech", tint: Brand.coral, page: .speech)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                pill(step: 2, stage: .polish, title: "Polish", tint: Brand.violet, page: .polish)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                pill(step: 3, stage: .translate, title: "Translate", tint: Color(hex: 0x3DD6C0), page: .translate)
                Spacer(minLength: 0)
            }
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.well))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.hairline, lineWidth: 0.5))
    }

    private func pill(step: Int, stage: HUDModel.Stage, title: String, tint: Color, page: Page) -> some View {
        let active = stage == current
        return Button {
            guard !active else { return }
            withAnimation(Motion.snappy) { navigator.page = page }
        } label: {
            HStack(spacing: 5) {
                Text("\(step)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(active ? .white : .secondary)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(active ? tint : Color.primary.opacity(0.08)))
                Text(title)
                    .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? .primary : .secondary)
                    .lineLimit(1)
            }
            .padding(.leading, 4)
            .padding(.trailing, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(active ? tint.opacity(0.14) : Color.clear))
            .overlay(Capsule().strokeBorder(active ? tint.opacity(0.32) : Color.hairline, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var caption: String {
        switch current {
        case .speech:
            return "Step 1 of 3 · Turns your voice into a raw transcript and passes it into Polish (then Translate when using \(settings.translateShortcut.display))."
        case .polish:
            return "Step 2 of 3 · Cleans fillers, false starts, and structure from Speech. Translate builds on this output, so tuning Polish improves both."
        case .translate:
            return "Step 3 of 3 · Translates Polish's cleaned text into \(targetLanguage) instead of raw spoken transcripts, keeping tone and meaning sharp."
        }
    }
}
