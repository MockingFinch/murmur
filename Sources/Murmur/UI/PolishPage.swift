import MurmurCore
import SwiftUI

struct PolishPage: View {
    @Bindable private var settings = AppSettings.shared
    @State private var check: CheckState = .idle

    var body: some View {
        PageHeader(symbol: "sparkles", gradient: Brand.polish, title: "Polish",
                   subtitle: "A language model tidies what you said, or rewrites what you selected, following your prompt.")

        PageSection(title: "Model API") {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    FieldLabel("Endpoint")
                    PlainField(placeholder: OpenRouterClient.defaultBase.absoluteString, text: $settings.openRouterBase, monospaced: true)
                    Hint(text: endpointHint, warning: endpointInvalid)

                    FieldLabel("API Key").padding(.top, 6)
                    SecretField(placeholder: settings.llmIsLocal ? "Not needed for a model on this Mac" : "Paste your API key",
                                text: $settings.openRouterKey)
                    Hint(text: "Saved on this Mac, readable only by your account. Leave it empty to insert the transcript as it is.")

                    FieldLabel("Model").padding(.top, 6)
                    PlainField(placeholder: AppSettings.defaultModel, text: $settings.openRouterModel, monospaced: true)
                    Hint(text: modelHint.text, warning: modelHint.warning)

                    CheckButton(title: "Test", state: check, disabled: !settings.polishReady) { test() }
                        .padding(.top, 6)
                }
            }
            Text("Any OpenAI-compatible API works: OpenRouter, OpenAI, DeepSeek, a model on this Mac. With OpenRouter, Murmur also asks the model for as little thinking as it allows, since thinking only slows a polish down.")
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
            Text("Used for both dictation and selections. Murmur tells the model which one it's getting, and to answer with the text alone.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }

        PageSection(title: "Try it") {
            Card { TryIt() }
        }
    }

    // MARK: Hints

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
        return ("OpenRouter doesn't list “\(id)”. Check the spelling.", true)
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
private struct TryIt: View {
    private let settings = AppSettings.shared
    @State private var input = "嗯，那个，我觉得这个方案呢其实还可以，就是那个时间上可能有点紧，呃，我们下周三之前能不能先出一个初版"
    @State private var output = ""
    @State private var status: String?
    @State private var failed = false
    @State private var running: Task<Void, Never>?
    @State private var started = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FieldLabel("As spoken")
            TextEditor(text: $input)
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
                    Label(running == nil ? "Polish" : "Stop", systemImage: running == nil ? "sparkles" : "stop.fill")
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
                    Text("Fill in the model API first.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .animation(Motion.gentle, value: status)

            if !output.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Polished")
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
        let instructions = settings.prompt
        running = Task {
            do {
                let out = try await client.polish(model: model, info: info,
                                                  instructions: instructions, input: text, source: .dictation) { p in
                    Task { @MainActor in show(p) }
                }
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
        case .retrying(let next, let reason): status = "Retrying (\(next) of 3): \(reason)"
        }
    }

    private func stop() {
        running?.cancel()
        running = nil
        status = "Stopped"
    }
}
