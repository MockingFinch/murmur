import MurmurCore
import SwiftUI

private struct ProviderPreset: Identifiable {
    let name: String
    let base: String
    let suggestedModel: String
    var id: String { name }

    static let all: [ProviderPreset] = [
        .init(name: "OpenRouter", base: "https://openrouter.ai/api/v1", suggestedModel: AppSettings.defaultModel),
        .init(name: "OpenAI", base: "https://api.openai.com/v1", suggestedModel: "gpt-4.1-mini"),
        .init(name: "DeepSeek", base: "https://api.deepseek.com/v1", suggestedModel: "deepseek-chat"),
        .init(name: "Ollama", base: "http://localhost:11434/v1", suggestedModel: "qwen3:8b"),
        .init(name: "LM Studio", base: "http://localhost:1234/v1", suggestedModel: "local-model"),
    ]
}

struct PolishPage: View {
    @Bindable private var settings = AppSettings.shared
    @State private var check: CheckState = .idle
    @State private var showCatalog = false

    var body: some View {
        PageHeader(symbol: "sparkles", gradient: Brand.polish, title: "Polish",
                   subtitle: "A language model tidies what you said, or rewrites what you selected, following your prompt.")

        PageSection(title: "Model API", trailing: settings.llmUsesOpenRouter
                    ? AnyView(LinkLabel(title: "OpenRouter keys", url: "https://openrouter.ai/keys"))
                    : nil) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        ForEach(ProviderPreset.all) { preset in
                            let active = settings.llmEndpoint?.absoluteString.lowercased() == preset.base.lowercased()
                            Button(preset.name) { apply(preset) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                                .foregroundStyle(active ? Color.white : Color.secondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(active ? AnyShapeStyle(Brand.polish) : AnyShapeStyle(Color.well))
                                )
                                .overlay(
                                    Capsule().strokeBorder(active ? Color.clear : Color.hairline, lineWidth: 0.5)
                                )
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 2)

                    FieldLabel("Endpoint")
                    PlainField(placeholder: OpenRouterClient.defaultBase.absoluteString, text: $settings.openRouterBase, monospaced: true)
                    Hint(text: endpointHint, warning: endpointInvalid)

                    FieldLabel("API Key").padding(.top, 6)
                    SecretField(placeholder: settings.llmIsLocal ? "Not needed for a model on this Mac" : "Paste your API key",
                                text: $settings.openRouterKey)
                    Hint(text: "Saved on this Mac, readable only by your account. Leave it empty to insert the transcript as it is.")

                    FieldLabel("Model").padding(.top, 6)
                    HStack(spacing: 8) {
                        PlainField(placeholder: AppSettings.defaultModel, text: $settings.openRouterModel, monospaced: true)
                        if settings.llmUsesOpenRouter, !ModelCatalog.shared.models.isEmpty {
                            Button("Browse…") { showCatalog = true }
                                .buttonStyle(.glass)
                                .popover(isPresented: $showCatalog, arrowEdge: .trailing) {
                                    ModelPickerPopover(selected: $settings.openRouterModel) {
                                        showCatalog = false
                                    }
                                }
                        }
                    }
                    Hint(text: modelHint.text, warning: modelHint.warning)

                    CheckButton(title: "Test", state: check, disabled: !settings.polishReady) { test() }
                        .padding(.top, 6)
                }
            }
            Text("Any OpenAI-compatible API works: OpenRouter, OpenAI, DeepSeek, or a model running on this Mac. With OpenRouter, Murmur asks the model for as little thinking as it allows, since thinking only slows a polish down.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .onChange(of: settings.openRouterBase) { check = .idle; refreshCatalog() }
        .onChange(of: settings.openRouterKey) { check = .idle }
        .onChange(of: settings.openRouterModel) { check = .idle }
        .onAppear { refreshCatalog() }

        PageSection(title: "Timeout") {
            Card {
                SettingRow(title: "Wait for the model",
                           detail: "Retries included. After that, the transcript goes in as Doubao heard it.") {
                    Picker("", selection: $settings.polishTimeout) {
                        ForEach(timeoutChoices, id: \.self) { s in
                            Text(s == OpenRouterClient.defaultTimeout ? "\(Int(s)) seconds (default)" : "\(Int(s)) seconds").tag(s)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }

        PageSection(title: "Prompt", trailing: settings.prompt == PolishPrompt.defaultInstructions ? nil : AnyView(
            Button("Restore Default") { withAnimation(Motion.gentle) { settings.prompt = PolishPrompt.defaultInstructions } }
                .buttonStyle(.link)
                .font(.system(size: 12))
        )) {
            Card(padding: 0) {
                TextEditor(text: $settings.prompt)
                    .font(.system(size: 12.5))
                    .lineSpacing(2.5)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .frame(minHeight: 260, maxHeight: 360)
            }
            Text("Used for both dictation and selections. Murmur tells the model which one it's getting, includes any custom vocabulary from Speech, and asks for the text alone.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }

        PageSection(title: "Try it") {
            Card { TryIt(job: .polish) }
        }
    }

    // MARK: Presets & hints

    private func apply(_ preset: ProviderPreset) {
        let currentModel = settings.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPresetModel = ProviderPreset.all.contains { $0.suggestedModel == currentModel }
        settings.openRouterBase = preset.base
        if currentModel.isEmpty || isPresetModel {
            settings.openRouterModel = preset.suggestedModel
        }
    }

    private var endpointInvalid: Bool {
        !settings.openRouterBase.trimmingCharacters(in: .whitespaces).isEmpty && settings.llmEndpoint == nil
    }

    private var endpointHint: String {
        if endpointInvalid { return "Enter a full address starting with https://" }
        guard let url = settings.llmEndpoint else { return "The address before /chat/completions." }
        return "Murmur calls \(url.absoluteString)/chat/completions"
    }

    /// What the model field means: on OpenRouter, the catalog can say whether the name exists.
    private var modelHint: (text: String, warning: Bool) {
        let id = settings.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty { return ("The model's name exactly as the API expects it.", false) }
        guard settings.llmUsesOpenRouter, !ModelCatalog.shared.models.isEmpty else {
            return ("The model's name exactly as the API expects it.", false)
        }
        if let info = settings.modelInfo { return ("\(info.name) · \(Price.text(info))", false) }
        return ("OpenRouter doesn't list “\(id)”. Check the spelling or click Browse.", true)
    }

    private var timeoutChoices: [Double] {
        let base: [Double] = [30, 60, 90, 120, 180, 240, 300]
        return base.contains(settings.polishTimeout) ? base : (base + [settings.polishTimeout]).sorted()
    }

    private func refreshCatalog() {
        if settings.llmUsesOpenRouter { ModelCatalog.shared.refresh() }
    }

    /// One real request with the endpoint, key and model as they are now:
    /// the quickest way to know all three are right.
    private func test() {
        check = .running
        let client = settings.openRouterClient(timeout: 30, attempts: 1)
        let model = settings.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = settings.modelInfo
        Task {
            let started = Date()
            do {
                _ = try await client.polish(model: model, info: info, instructions: "Repeat the text exactly.",
                                            input: "OK.", source: .dictation) { _ in }
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                check = .passed("\(model) answered in \(ms) ms")
            } catch {
                check = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}

// MARK: - OpenRouter model picker

private struct ModelPickerPopover: View {
    @Binding var selected: String
    let close: () -> Void
    @State private var query = ""
    private let catalog = ModelCatalog.shared

    /// Fast, low-latency models well suited to dictation polishing.
    private static let recommendedIDs: [String] = [
        "google/gemini-3.1-flash-lite",
        "google/gemini-2.5-flash-lite",
        "google/gemini-2.5-flash",
        "openai/gpt-4.1-nano",
        "openai/gpt-4.1-mini",
        "anthropic/claude-haiku-4.5",
        "deepseek/deepseek-chat-v3-0324",
    ]

    private var filtered: [OpenRouterModel] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            let rec = Self.recommendedIDs.compactMap { id in catalog.models.first { $0.id == id } }
            let rest = catalog.models.filter { m in !Self.recommendedIDs.contains(m.id) }
                .sorted { $0.created > $1.created }
                .prefix(40)
            return rec + rest
        }
        return catalog.models.filter {
            $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q)
        }
        .prefix(60)
        .map { $0 }
    }

    var body: some View {
        VStack(spacing: 10) {
            PlainField(placeholder: "Search OpenRouter models…", text: $query)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Suggested for dictation")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 2)
                    }
                    ForEach(filtered) { model in
                        let active = selected.trimmingCharacters(in: .whitespacesAndNewlines) == model.id
                        Button {
                            selected = model.id
                            close()
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.name)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text("\(model.id) · \(Price.text(model))")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                if active {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(active ? Color.accentColor.opacity(0.12) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 300)
        }
        .padding(12)
        .frame(width: 390)
    }
}

private struct Hint: View {
    let text: String
    var warning = false

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(warning ? AnyShapeStyle(Brand.amber) : AnyShapeStyle(.tertiary))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.opacity)
            .animation(Motion.gentle, value: text)
    }
}

enum Price {
    static func text(_ m: OpenRouterModel) -> String {
        if m.inputPrice == 0, m.outputPrice == 0 { return "Free" }
        return "$\(short(m.inputPrice)) in · $\(short(m.outputPrice)) out per M tokens"
    }

    private static func short(_ v: Double) -> String {
        v >= 10 ? String(format: "%.0f", v) : v >= 1 ? String(format: "%.2f", v).replacingOccurrences(of: ".00", with: "")
            : String(format: "%.3f", v).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }
}

// MARK: - Try it

/// The real request, on a sample: the quickest way to see the prompt and
/// the model work together.
struct TryIt: View {
    enum Job { case polish, translate }

    let job: Job
    private let settings = AppSettings.shared
    @State private var input: String
    @State private var source: PolishPrompt.Source = .dictation
    @State private var userEdited = false
    @State private var output = ""
    @State private var status: String?
    @State private var failed = false
    @State private var running: Task<Void, Never>?
    @State private var started = Date()

    private static let polishSamples: [(title: String, source: PolishPrompt.Source, text: String)] = [
        ("Mixed CN/EN", .dictation, "嗯，那个，我觉得这个方案呢其实还可以，就是那个 API 的 response time 有点慢，呃，我们下周三之前能不能先出一个初版"),
        ("English", .dictation, "Um, so for next week, uh, let's meet on Tuesday, no sorry Wednesday at three to review the onboarding draft."),
        ("Selection", .selection, "so basically signups went down mostly because the new form is way too long and people just give up halfway"),
    ]
    private static let chineseTranslateSample = "我觉得这个方案其实还可以，就是时间上可能有点紧。我们下周三之前能不能先出一个初版？"
    private static let englishTranslateSample = "I think this plan looks solid overall, though the timeline is a bit tight. Could we get a first draft out by next Wednesday?"

    init(job: Job) {
        self.job = job
        let initial: String
        if job == .polish {
            initial = Self.polishSamples[0].text
        } else {
            let lang = TranslatePrompt.language(AppSettings.shared.translateLanguage).lowercased()
            initial = (lang.contains("chinese") || lang.contains("cantonese"))
                ? Self.englishTranslateSample : Self.chineseTranslateSample
        }
        _input = State(initialValue: initial)
    }

    private var verb: String { job == .polish ? "Polish" : "Translate" }
    private var targetLanguage: String { TranslatePrompt.language(settings.translateLanguage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                FieldLabel(job == .polish ? (source == .dictation ? "As spoken" : "Selected text") : "Text")
                Spacer()
                if job == .polish {
                    Picker("", selection: $source) {
                        Text("Dictation").tag(PolishPrompt.Source.dictation)
                        Text("Selection").tag(PolishPrompt.Source.selection)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 156)
                }
            }

            if job == .polish {
                HStack(spacing: 6) {
                    ForEach(Self.polishSamples, id: \.title) { sample in
                        Button(sample.title) {
                            source = sample.source
                            input = sample.text
                            userEdited = false
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.well))
                        .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 0.5))
                    }
                    Spacer()
                }
            }

            TextEditor(text: Binding(
                get: { input },
                set: { input = $0; userEdited = true }
            ))
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 64)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.well))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.hairline, lineWidth: 0.5))

            HStack(spacing: 10) {
                Button {
                    running == nil ? run() : stop()
                } label: {
                    Label(running == nil ? verb : "Stop",
                          systemImage: running == nil ? (job == .polish ? "sparkles" : "translate") : "stop.fill")
                        .labelStyle(.titleAndIcon)
                        .frame(minWidth: 80)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glassProminent)
                .tint(Brand.violet)
                .disabled(!settings.polishReady || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let status {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(failed ? AnyShapeStyle(Brand.coral) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                        .transition(.opacity)
                } else if !settings.polishReady {
                    Text(job == .polish ? "Fill in the model API first." : "Set up the model API in Polish first.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .animation(Motion.gentle, value: status)

            if !output.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(job == .polish ? "Polished" : "Translated to \(targetLanguage)")
                    Text(output)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.violet.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Brand.violet.opacity(0.2), lineWidth: 0.5))
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Motion.smooth, value: output.isEmpty)
        .onChange(of: settings.translateLanguage) {
            guard job == .translate, !userEdited else { return }
            let lang = targetLanguage.lowercased()
            input = (lang.contains("chinese") || lang.contains("cantonese"))
                ? Self.englishTranslateSample : Self.chineseTranslateSample
        }
    }

    private func run() {
        output = ""
        failed = false
        status = "Sending…"
        started = Date()
        let model = settings.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = settings.openRouterClient()
        let info = settings.modelInfo
        let text = input
        let job = self.job
        let source = self.source
        let vocabulary = settings.vocabularyTerms
        let instructions = job == .polish ? settings.prompt : settings.translatePrompt
        let language = settings.translateLanguage
        running = Task {
            do {
                let report: @Sendable (PolishProgress) -> Void = { p in Task { @MainActor in show(p) } }
                let out = job == .polish
                    ? try await client.polish(model: model, info: info, instructions: instructions, input: text,
                                              source: source, vocabulary: vocabulary, progress: report)
                    : try await client.translate(model: model, info: info, instructions: instructions, input: text,
                                                 language: language, progress: report)
                output = out.text
                let s = Date().timeIntervalSince(started)
                status = String(format: "Done in %.1f s", s) + (out.attempts > 1 ? " · \(out.attempts) attempts" : "")
                    + (out.servedBy.map { " · \($0)" } ?? "")
            } catch {
                let f = error as? PolishFailure
                if f?.kind != .cancelled {
                    failed = true
                    status = f?.message ?? error.localizedDescription
                }
            }
            running = nil
        }
    }

    private func show(_ p: PolishProgress) {
        guard running != nil else { return }
        switch p {
        case .attempt(let n): status = n == 1 ? "Waiting for the model…" : "Attempt \(n)…"
        case .thinking: status = "Thinking…"
        case .text(let t): output = PolishPrompt.clean(t, input: input); status = "Writing…"
        case .retrying(let next, let reason): status = "Retrying (\(next) of \(OpenRouterClient.maxAttempts)): \(reason)"
        }
    }

    private func stop() {
        running?.cancel()
        running = nil
        status = "Stopped"
    }
}
