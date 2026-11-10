import AppKit
import MurmurCore

enum Page: String, CaseIterable, Identifiable, Hashable {
    case overview, speech, polish, translate, shortcut
    var id: String { rawValue }
}

/// The one owner of a session: what the shortcuts do, in what order.
///
///   dictate (⌃X) ───┬─ text selected (and a model set up) → refine it → replace it
///                   └─ otherwise → listen … shortcut → complete text from Doubao
///                                                     → polish → insert
///   translate (⌃⌘X) ┬─ text selected → translate it → replace it
///                   └─ otherwise → the same dictation, then polish → translate → insert
///
///   The shortcut that starts a session decides what it is; either one ends
///   it. Esc is left to the app in front. (The menu bar item can cancel.)
@MainActor
final class DictationEngine {
    enum State { case idle, arming, listening, working }
    /// What a session is for.
    enum Intent { case dictate, translate }

    static let shared = DictationEngine()

    let hud = HUDModel()
    private(set) var state: State = .idle { didSet { onStateChange?(state) } }
    /// The current (or last) session's intent.
    private(set) var intent: Intent = .dictate
    var onStateChange: ((State) -> Void)?
    /// Opens the settings window on a page (for problems only the user can fix).
    var openSettings: ((Page) -> Void)?

    private let settings = AppSettings.shared
    private var capture: AudioCapture?
    private var transcriber: LiveTranscriber?
    private var work: Task<Void, Never>?
    private var autoStop: Task<Void, Never>?
    private var lastPress = Date.distantPast
    /// Numbers sessions: a late callback from a cancelled one changes nothing.
    private var run = 0

    static let maxRecording: TimeInterval = 15 * 60

    // MARK: Entry points

    /// A press of either shortcut: starts a session with that intent, or
    /// ends the one that's listening, whichever shortcut started it.
    func press(_ intent: Intent) {
        let now = Date()
        guard now.timeIntervalSince(lastPress) > 0.25 else { return }
        lastPress = now
        switch state {
        case .idle: begin(intent)
        case .listening: stopListening()
        case .arming, .working: hud.nudge()
        }
    }

    func cancel() {
        guard state != .idle else { return }
        run += 1
        work?.cancel()
        autoStop?.cancel()
        transcriber?.cancel()
        capture?.stop()
        transcriber = nil
        capture = nil
        hud.finish(.cancelled)
        state = .idle
    }

    // MARK: Starting

    private func begin(_ intent: Intent) {
        run += 1
        let id = run
        self.intent = intent
        // Translation needs the model; better to say so now than after a dictation.
        if intent == .translate, !settings.polishReady {
            setupProblem("Set up a model to translate", "Translation uses the model API from Polish.", page: .polish)
            return
        }
        state = .arming
        // The microphone starts at once, before we know whether this is a
        // dictation: the first syllable is never lost to the selection check.
        var early: AudioCapture?
        if Permissions.microphone == .authorized, settings.speechReady {
            early = makeCapture()
            do { try early?.start() } catch { early = nil }
        }
        work = Task { [weak self] in await self?.decide(early, id) }
    }

    private func decide(_ early: AudioCapture?, _ id: Int) async {
        if settings.polishReady, Permissions.accessibility, let selection = await TextBridge.readSelection() {
            early?.stop()
            guard id == run else { return }
            await rework(selection, id)
            return
        }
        guard id == run else { early?.stop(); return }
        guard settings.speechReady else {
            early?.stop()
            setupProblem("Set up Doubao to dictate", "Add your Doubao key in Speech.", page: .speech)
            return
        }
        var capture = early
        if capture == nil {
            switch Permissions.microphone {
            case .notDetermined:
                guard await Permissions.requestMicrophone() else {
                    setupProblem("Murmur can't hear you", "Allow the microphone to dictate.", page: .shortcut)
                    return
                }
            case .denied, .restricted:
                setupProblem("Murmur can't hear you", "Allow the microphone in System Settings.", page: .shortcut)
                Permissions.open(.microphone)
                return
            default:
                break
            }
            guard id == run else { return }
            let c = makeCapture()
            do {
                try c.start()
                capture = c
            } catch {
                problem("Couldn't start the microphone", error.localizedDescription)
                return
            }
        }
        guard let capture, id == run else { capture?.stop(); return }
        listen(capture, id)
    }

    private func makeCapture() -> AudioCapture {
        let c = AudioCapture()
        let hud = self.hud
        c.onLevels = { levels in MainActor.assumeIsolated { hud.push(levels) } }
        return c
    }

    // MARK: Dictation

    private func listen(_ capture: AudioCapture, _ id: Int) {
        guard let credentials = settings.doubaoCredentials else { return }
        self.capture = capture
        state = .listening
        hud.startListening(translatingTo: intent == .translate ? targetLanguage : nil)
        Cue.play(.start)
        if settings.polishReady { settings.openRouterClient().warmUp() }

        let hud = self.hud
        let transcriber = LiveTranscriber(
            credentials: credentials, tape: capture.tape,
            onPartial: { text in DispatchQueue.main.async { MainActor.assumeIsolated { hud.liveText = text } } },
            onRetry: { n in DispatchQueue.main.async { MainActor.assumeIsolated { hud.show(.transcribing(retry: n)) } } }
        )
        self.transcriber = transcriber
        transcriber.start()

        autoStop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.maxRecording * 1_000_000_000))
            guard !Task.isCancelled, let self, self.run == id, self.state == .listening else { return }
            self.stopListening()
        }
    }

    private func stopListening() {
        guard state == .listening, let capture, let transcriber else { return }
        let id = run
        state = .working
        autoStop?.cancel()
        capture.stop()
        Cue.play(.stop)
        let stoppedAt = Date()
        hud.show(.transcribing(retry: 0))
        work = Task { [weak self] in await self?.complete(transcriber, stoppedAt, id) }
    }

    private func complete(_ transcriber: LiveTranscriber, _ stoppedAt: Date, _ id: Int) async {
        let outcome: LiveTranscriber.Outcome
        do {
            outcome = try await transcriber.finish()
        } catch {
            guard id == run else { return }
            let e = error as? SpeechError ?? SpeechError(.network, error.localizedDescription)
            if e.kind == .cancelled { return }
            if e.kind == .auth || e.kind == .quota || e.kind == .config {
                setupProblem("Doubao refused the request", e.message, page: .speech)
            } else {
                problem("Couldn't transcribe", e.message)
            }
            return
        }
        guard id == run else { return }

        let raw = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            end(.notice(.init(tone: .info, title: "No speech detected", detail: nil)))
            return
        }

        var text = raw
        var polish = UsageRecord.Polish.skipped
        var attempts = 0
        var polishProblem: String?
        if settings.polishReady {
            hud.preview = raw
            hud.liveText = ""
            hud.show(.model(.polish, retry: 0, thinking: false))
            do {
                let out = try await polishText(raw, .dictation)
                text = out.text
                polish = .polished
                attempts = out.attempts
            } catch {
                let f = error as? PolishFailure
                if f?.kind == .cancelled || id != run { return }
                polish = .fallback
                attempts = OpenRouterClient.Tuning().attempts
                polishProblem = f?.message ?? error.localizedDescription
            }
        }
        guard id == run else { return }

        // Translation takes the polished text. If polishing failed, the model
        // is unlikely to do better a second time, and the wait has been long
        // enough: the transcript goes in as heard.
        var translated = false
        var translateProblem: String?
        if intent == .translate, polishProblem == nil, !text.isEmpty {
            hud.preview = text
            hud.liveText = ""
            hud.show(.model(.translate(targetLanguage), retry: 0, thinking: false))
            do {
                let out = try await translateText(text)
                text = out.text
                translated = true
                attempts += out.attempts
            } catch {
                let f = error as? PolishFailure
                if f?.kind == .cancelled || id != run { return }
                attempts += OpenRouterClient.Tuning().attempts
                translateProblem = f?.message ?? error.localizedDescription
            }
            guard id == run else { return }
        }

        if text.isEmpty {
            end(.notice(.init(tone: .info, title: "Nothing to insert", detail: "The model found no words worth keeping.")))
            return
        }

        let pasted = await TextBridge.paste(text)
        UsageStore.shared.add(UsageRecord(kind: .dictation, audioSeconds: outcome.seconds, text: text, polish: polish,
                                          waitSeconds: Date().timeIntervalSince(stoppedAt), attempts: attempts,
                                          translated: translated))
        switch pasted {
        case .copied(let why):
            end(.notice(.init(tone: .warning, title: translated ? "Translation copied to the clipboard" : "Copied to the clipboard",
                              detail: why)))
        case .pasted:
            if let polishProblem {
                Cue.play(.problem)
                end(.notice(.init(tone: .warning,
                                  title: intent == .translate ? "Inserted as heard, untranslated" : "Inserted without polishing",
                                  detail: polishProblem)))
            } else if let translateProblem {
                Cue.play(.problem)
                end(.notice(.init(tone: .warning, title: "Inserted without translating", detail: translateProblem)))
            } else if outcome.partial {
                end(.notice(.init(tone: .warning, title: "Inserted, but the end may be missing", detail: "Doubao never confirmed the final text.")))
            } else {
                end(.done(translated ? "Translated, inserted and copied" : "Inserted and copied"))
            }
        }
    }

    // MARK: Refining or translating a selection

    private func rework(_ selection: TextBridge.Selection, _ id: Int) async {
        let translating = intent == .translate
        let language = targetLanguage
        let verb = translating ? "translate" : "refine"
        state = .working
        let started = Date()
        hud.reset()
        hud.preview = selection.text
        hud.show(.model(translating ? .translate(language) : .refine, retry: 0, thinking: false))

        let out: PolishOutput
        do {
            out = translating ? try await translateText(selection.text) : try await polishText(selection.text, .selection)
        } catch {
            let f = error as? PolishFailure
            if f?.kind == .cancelled || id != run { return }
            if f?.kind == .auth || f?.kind == .credits || f?.kind == .model {
                setupProblem("Couldn't \(verb) the selection", f?.message ?? error.localizedDescription, page: .polish)
            } else {
                problem("Couldn't \(verb) the selection", f?.message ?? error.localizedDescription)
            }
            return
        }
        guard id == run else { return }

        // A selection translation never asked for a polish: it stays out of
        // the polish rate.
        let record = UsageRecord(kind: .refine, audioSeconds: 0, text: out.text, polish: translating ? .skipped : .polished,
                                 waitSeconds: Date().timeIntervalSince(started), attempts: out.attempts,
                                 translated: translating)
        if out.text == selection.text {
            UsageStore.shared.add(record)
            end(.done(translating ? "Already in \(language)" : "Already reads well"))
            return
        }
        guard TextBridge.isStillSelected(selection) else {
            Clipboard.put(out.text)
            UsageStore.shared.add(record)
            end(.notice(.init(tone: .warning, title: translating ? "Translation copied" : "Refined text copied",
                              detail: "The selection changed, so Murmur left it alone. Paste with ⌘V.")))
            return
        }
        let pasted = await TextBridge.paste(out.text)
        UsageStore.shared.add(record)
        switch pasted {
        case .pasted: end(.done(translating ? "Translated, replaced and copied" : "Replaced and copied"))
        case .copied(let why): end(.notice(.init(tone: .warning, title: "Copied to the clipboard", detail: why)))
        }
    }

    // MARK: Helpers

    /// The language translations go into, as the model is told it.
    private var targetLanguage: String { TranslatePrompt.language(settings.translateLanguage) }

    private func polishText(_ text: String, _ source: PolishPrompt.Source) async throws -> PolishOutput {
        let client = settings.openRouterClient()
        let model = settings.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let hud = self.hud
        return try await client.polish(model: model, info: settings.modelInfo,
                                       instructions: settings.prompt, input: text, source: source) { progress in
            DispatchQueue.main.async { MainActor.assumeIsolated { hud.apply(progress) } }
        }
    }

    /// The same model and timeout as polishing, with the translation prompt.
    private func translateText(_ text: String) async throws -> PolishOutput {
        let client = settings.openRouterClient()
        let model = settings.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let hud = self.hud
        return try await client.translate(model: model, info: settings.modelInfo, instructions: settings.translatePrompt,
                                          input: text, language: targetLanguage) { progress in
            DispatchQueue.main.async { MainActor.assumeIsolated { hud.apply(progress) } }
        }
    }

    private func end(_ mode: HUDModel.Mode) {
        autoStop?.cancel()
        transcriber = nil
        capture = nil
        hud.finish(mode)
        state = .idle
    }

    private func problem(_ title: String, _ detail: String?) {
        Cue.play(.problem)
        end(.notice(.init(tone: .error, title: title, detail: detail)))
    }

    private func setupProblem(_ title: String, _ detail: String, page: Page) {
        problem(title, detail)
        openSettings?(page)
    }
}
