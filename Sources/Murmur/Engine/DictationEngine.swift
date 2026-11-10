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
///
///   Nothing said is lost:
///   - to the network: the stream to Doubao reconnects as often as it
///     takes while the user speaks, keeping every sentence it confirmed;
///   - to Doubao never coming back: what it confirmed goes in, and the
///     recording, on disk from the first syllable, stays to transcribe again;
///   - to a crash or a quit: that recording is offered at the next launch;
///   - to the model: each request gets up to five attempts, and if
///     polishing still fails the transcript goes in as Doubao heard it; if
///     translating fails, the polished text goes in.
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

    /// The last dictation's transcript as Doubao heard it, before the
    /// model changed it. In memory only.
    private(set) var lastHeard: String?
    /// The last text Murmur inserted or copied. In memory only.
    private(set) var lastResult: String?
    private let settings = AppSettings.shared
    private var capture: AudioCapture?
    private var transcriber: ResilientTranscriber?
    /// Writes the current recording to disk while it's spoken.
    private var writer: RecordingWriter?
    /// The saved recording behind the current session: deleted once its
    /// words are in, kept if they aren't.
    private var saved: String?
    /// Recordings whose words aren't all in yet.
    let recordings = RecordingStore(directory: AppFiles.directory.appendingPathComponent("Recordings", isDirectory: true))
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
        let speaking = state != .working
        run += 1
        work?.cancel()
        autoStop?.cancel()
        transcriber?.cancel()
        capture?.stop()
        writer?.close()
        writer = nil
        transcriber = nil
        capture = nil
        // Cancelling while speaking means "never mind". Once the user has
        // stopped, they said what they meant: giving up on the wait keeps
        // the recording.
        if speaking { forgetSaved() }
        if saved != nil {
            saved = nil
            hud.finish(.notice(.init(tone: .info, title: "Cancelled", detail: Self.savedNote)))
        } else {
            hud.finish(.cancelled)
        }
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
        c.onLost = { MainActor.assumeIsolated { DictationEngine.shared.microphoneLost() } }
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

        // On disk from the first syllable, until the words are in.
        let writer = recordings.begin(translate: intent == .translate)
        writer?.follow(capture.tape)
        self.writer = writer
        saved = writer?.id

        let transcriber = makeTranscriber(credentials, capture.tape, id)
        self.transcriber = transcriber
        transcriber.start()

        autoStop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.maxRecording * 1_000_000_000))
            guard !Task.isCancelled, let self, self.run == id, self.state == .listening else { return }
            self.stopListening(.limit)
        }
    }

    /// Why listening ended, when it wasn't the user's choice.
    private enum StopReason { case user, limit, microphoneLost }

    /// No microphone left to listen with: what was said so far goes in.
    private func microphoneLost() {
        guard state == .listening else { return }
        stopListening(.microphoneLost)
    }

    private func stopListening(_ reason: StopReason = .user) {
        guard state == .listening, let capture, let transcriber else { return }
        let id = run
        state = .working
        autoStop?.cancel()
        capture.stop()
        writer?.close()
        writer = nil
        Cue.play(.stop)
        let stoppedAt = Date()
        hud.show(.transcribing(retry: hud.link == .reconnecting ? 1 : 0))
        work = Task { [weak self] in await self?.transcribe(transcriber, stoppedAt, id, reason) }
    }

    /// Transcribes a recording that was saved because its words never all
    /// came back, then carries on as if it had just been spoken.
    func transcribeAgain(_ recording: RecordingStore.Recording) {
        guard state == .idle else { hud.nudge(); return }
        guard let credentials = settings.doubaoCredentials else {
            setupProblem("Set up Doubao to transcribe", "Add your Doubao key in Speech.", page: .speech)
            return
        }
        guard let audio = recordings.audio(recording.id), audio.count >= PCMTape.bytesPerSecond / 4 else {
            recordings.delete(recording.id)
            problem("That recording is gone", nil)
            return
        }
        run += 1
        let id = run
        intent = recording.translate && settings.polishReady ? .translate : .dictate
        state = .working
        saved = recording.id
        hud.reset()
        hud.show(.transcribing(retry: 0))
        if settings.polishReady { settings.openRouterClient().warmUp() }
        let transcriber = makeTranscriber(credentials, PCMTape(audio), id)
        self.transcriber = transcriber
        let started = Date()
        work = Task { [weak self] in await self?.transcribe(transcriber, started, id, .user, again: true) }
    }

    private func makeTranscriber(_ credentials: DoubaoCredentials, _ tape: PCMTape, _ id: Int) -> ResilientTranscriber {
        ResilientTranscriber(
            credentials: credentials, tape: tape,
            onText: { text in DispatchQueue.main.async { MainActor.assumeIsolated { DictationEngine.shared.heard(text, id) } } },
            onStatus: { status in DispatchQueue.main.async { MainActor.assumeIsolated { DictationEngine.shared.reflect(status, id) } } }
        )
    }

    private func heard(_ text: String, _ id: Int) {
        guard id == run else { return }
        switch hud.mode {
        case .listening, .transcribing: hud.liveText = text
        default: break
        }
    }

    /// The stream's health, in the capsule: a chip while the user speaks
    /// (they can keep going: the recording is safe), the attempt after.
    private func reflect(_ status: ResilientTranscriber.Status, _ id: Int) {
        guard id == run else { return }
        let transcribing: Bool = { if case .transcribing = hud.mode { return true }; return false }()
        switch status {
        case .live:
            hud.link = .live
            if transcribing { hud.show(.transcribing(retry: 0)) }
        case .reconnecting(let attempt, _):
            if state == .listening { hud.link = .reconnecting } else if transcribing { hud.show(.transcribing(retry: attempt)) }
        case .unavailable:
            if state == .listening { hud.link = .recordingOnly }
        }
    }

    private func transcribe(_ transcriber: ResilientTranscriber, _ stoppedAt: Date, _ id: Int,
                            _ reason: StopReason, again: Bool = false) async {
        let outcome: ResilientTranscriber.Outcome
        do {
            outcome = try await transcriber.finish()
        } catch {
            guard id == run else { return }
            let e = error as? SpeechError ?? SpeechError(.network, error.localizedDescription)
            if e.kind == .cancelled { return }
            let detail = saved == nil ? e.message : "\(e.message) \(Self.savedNote)"
            if e.kind == .auth || e.kind == .quota || e.kind == .config {
                setupProblem("Doubao refused the request", detail, page: .speech)
            } else {
                problem("Couldn't transcribe", detail)
            }
            return
        }
        guard id == run else { return }
        await deliver(outcome, stoppedAt, id, reason, again: again)
    }

    private func deliver(_ outcome: ResilientTranscriber.Outcome, _ stoppedAt: Date, _ id: Int,
                         _ reason: StopReason, again: Bool) async {
        let raw = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            forgetSaved()
            end(.notice(.init(tone: .info, title: "No speech detected", detail: nil)))
            return
        }

        lastHeard = raw
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
                attempts += out.attempts
                if out.text.isEmpty {
                    // Never trade the polished text for nothing.
                    translateProblem = "The model returned no translation."
                } else {
                    text = out.text
                    translated = true
                }
            } catch {
                let f = error as? PolishFailure
                if f?.kind == .cancelled || id != run { return }
                attempts += OpenRouterClient.Tuning().attempts
                translateProblem = f?.message ?? error.localizedDescription
            }
            guard id == run else { return }
        }

        if text.isEmpty {
            // The model judged it all filler. In case it was wrong, what
            // Doubao heard is kept on the clipboard.
            Clipboard.put(raw)
            if outcome.isComplete { forgetSaved() }
            end(.notice(.init(tone: .info, title: "Nothing to insert",
                              detail: "The model found no words worth keeping. What Doubao heard is on the clipboard.")))
            return
        }

        lastResult = text
        let pasted = await TextBridge.paste(text)
        // A recording transcribed again was counted, if at all, the first time.
        if !again {
            UsageStore.shared.add(UsageRecord(kind: .dictation, audioSeconds: outcome.seconds, text: text, polish: polish,
                                              waitSeconds: Date().timeIntervalSince(stoppedAt), attempts: attempts,
                                              translated: translated))
        }
        // Only words that are all in let the recording go.
        if outcome.isComplete { forgetSaved() }
        let missing = outcome.isComplete ? nil : "The last \(Self.duration(outcome.unconfirmedSeconds)) is missing"
        switch pasted {
        case .copied(let why):
            let title = translated ? "Translation copied to the clipboard" : "Copied to the clipboard"
            if let missing {
                Cue.play(.problem)
                end(.notice(.init(tone: .warning, title: title, detail: "\(missing). \(Self.savedNote)")))
            } else {
                end(.notice(.init(tone: .warning, title: title, detail: why)))
            }
        case .pasted:
            if let missing {
                Cue.play(.problem)
                end(.notice(.init(tone: .warning, title: "Inserted, but \(missing.prefix(1).lowercased() + missing.dropFirst())",
                                  detail: "\(Self.savedNote)\(outcome.problem.map { " Doubao: \($0)" } ?? "")")))
            } else if let polishProblem {
                Cue.play(.problem)
                end(.notice(.init(tone: .warning,
                                  title: intent == .translate ? "Inserted as heard, untranslated" : "Inserted without polishing",
                                  detail: polishProblem)))
            } else if let translateProblem {
                Cue.play(.problem)
                end(.notice(.init(tone: .warning, title: "Inserted without translating", detail: translateProblem)))
            } else if reason == .limit {
                end(.notice(.init(tone: .info, title: translated ? "Translated, inserted and copied" : "Inserted and copied",
                                  detail: "Dictations stop at \(Int(Self.maxRecording / 60)) minutes. Press \(settings.shortcut.display) to go on.")))
            } else if reason == .microphoneLost {
                Cue.play(.problem)
                end(.notice(.init(tone: .warning, title: translated ? "Translated, inserted and copied" : "Inserted and copied",
                                  detail: "The microphone went away, so the dictation stopped there.")))
            } else {
                end(.done(translated ? "Translated, inserted and copied" : "Inserted and copied"))
            }
        }
    }

    /// How a saved recording is found again.
    private static let savedNote = "The recording is saved: Transcribe Again from the menu bar."

    /// The recording behind this session is no longer needed.
    private func forgetSaved() {
        if let saved { recordings.delete(saved) }
        saved = nil
    }

    /// Murmur is quitting: what is being recorded is written out, and
    /// offered again at the next launch.
    func prepareForQuit() {
        writer?.close()
        writer = nil
    }

    /// Recordings left by a crash, a quit or a failure, offered again.
    func recoverAtLaunch() {
        recordings.prune()
        let left = recordings.all()
        guard !left.isEmpty else { return }
        hud.finish(.notice(.init(tone: .warning,
                                 title: left.count == 1 ? "A recording wasn't transcribed" : "\(left.count) recordings weren't transcribed",
                                 detail: "Nothing is lost: transcribe it again from the Murmur menu bar.")))
    }

    static func duration(_ seconds: Double) -> String {
        let s = max(1, Int(seconds.rounded(.up)))
        return s < 60 ? "\(s) s" : String(format: "%d:%02d", s / 60, s % 60)
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
        lastResult = out.text
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
        writer?.close()
        writer = nil
        saved = nil
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
