import AppKit
import MurmurCore

enum Page: String, CaseIterable, Identifiable, Hashable {
    case overview, speech, polish, translate, general
    var id: String { rawValue }
}

/// The one owner of a session: what the shortcuts do, in what order.
///
///   dictate (⌃X) ───┬─ text selected (and a model set up) → refine it → replace it
///                   └─ otherwise → listen … shortcut (or release after hold)
///                                           → complete text from Doubao → polish → insert
///   translate (⌃⌘X) ┬─ text selected → translate it → replace it
///                   └─ otherwise → the same dictation, then polish → translate → insert
///
///   The shortcut that starts a session decides what it is; either one ends
///   it. Holding the starting shortcut past 0.4 s stops on release. Esc cancels
///   a recording while listening (double-Esc once substantial speech exists).
@MainActor
final class DictationEngine {
    enum State { case idle, arming, listening, working }
    /// What a session is for.
    enum Intent { case dictate, translate }

    /// The most recent warning or error, kept in memory so the menu bar can
    /// explain what went wrong even after the floating capsule fades out.
    struct LastIssue: Equatable {
        var title: String
        var detail: String?
        var date: Date
        var page: Page?
    }

    static let shared = DictationEngine()

    let hud = HUDModel()
    private(set) var state: State = .idle { didSet { onStateChange?(state) } }
    /// The current (or last) session's intent.
    private(set) var intent: Intent = .dictate
    var onStateChange: ((State) -> Void)?
    /// Fired when saved recordings or `lastIssue` change, so the menu bar badge updates.
    var onInventoryChange: (() -> Void)?
    /// Opens the settings window on a page (for problems only the user can fix).
    var openSettings: ((Page) -> Void)?

    /// The last dictation's transcript as Doubao heard it, before the
    /// model changed it. In memory only.
    private(set) var lastHeard: String?
    /// The last text Murmur inserted or copied. In memory only.
    private(set) var lastResult: String?
    /// The last warning or error from a session, cleared on the next clean completion.
    private(set) var lastIssue: LastIssue?

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
    private var armingReveal: Task<Void, Never>?
    /// Ends a dictation by itself: at the length limit, or once Doubao has
    /// heard nothing new for a while.
    private var autoStop: Task<Void, Never>?
    /// How long Doubao has heard nothing new, while it's connected.
    private var silence: SilenceWatch?
    /// The quiet allowed in the current dictation, as set when it began (0 = off).
    private var quietLimit = SilenceWatch.defaultLimit
    private var lastPress = Date.distantPast
    /// Hybrid tap-to-toggle / hold-to-talk tracking.
    private var pressStartedAt: Date?
    private var holdSessionRun: Int?
    private var pendingHoldStopRun: Int?
    /// Numbers sessions: a late callback from a cancelled one changes nothing.
    private var run = 0

    static let maxRecording: TimeInterval = 15 * 60
    /// Holding a shortcut at least this long switches to release-to-stop.
    private static let holdThreshold: TimeInterval = 0.4
    /// Substantial recordings require a second Esc to prevent accidental loss.
    private static let guardedEscapeSeconds: TimeInterval = 10
    private static let guardedEscapeChars = 20

    // MARK: Entry points

    /// A press of either shortcut: starts a session with that intent, or
    /// ends the one that's listening, whichever shortcut started it.
    func press(_ intent: Intent) {
        let now = Date()
        guard now.timeIntervalSince(lastPress) > 0.25 else { return }
        lastPress = now
        switch state {
        case .idle:
            pressStartedAt = now
            begin(intent)
            holdSessionRun = run
            pendingHoldStopRun = nil
        case .listening:
            holdSessionRun = nil
            pendingHoldStopRun = nil
            stopListening()
        case .arming, .working:
            hud.nudge()
        }
    }

    /// Releasing a shortcut after holding it at least `holdThreshold` stops
    /// the dictation it started (hybrid hold-to-talk). Quick taps stay in toggle mode.
    func release(_ intent: Intent) {
        guard holdSessionRun == run, let started = pressStartedAt else { return }
        let held = Date().timeIntervalSince(started)
        holdSessionRun = nil
        pressStartedAt = nil
        guard held >= Self.holdThreshold else { return }
        if state == .listening {
            stopListening()
        } else if state == .arming {
            pendingHoldStopRun = run
        }
    }

    /// Global Esc while listening: cancels immediately for quick false starts,
    /// or asks for a second press once substantial speech has been captured.
    func pressEscape() {
        guard state == .listening else { return }
        let substantial = Date().timeIntervalSince(hud.startedAt) >= Self.guardedEscapeSeconds
            || TextMetrics.visibleCharacters(hud.liveText) >= Self.guardedEscapeChars
        if substantial, !hud.escapeConfirm {
            hud.armEscapeConfirm()
            hud.nudge()
            return
        }
        cancel()
    }

    func cancel() {
        guard state != .idle else { return }
        let speaking = state != .working
        run += 1
        armingReveal?.cancel()
        armingReveal = nil
        work?.cancel()
        autoStop?.cancel()
        silence = nil
        holdSessionRun = nil
        pendingHoldStopRun = nil
        pressStartedAt = nil
        transcriber?.cancel()
        capture?.stop()
        writer?.close()
        writer = nil
        transcriber = nil
        capture = nil
        Cue.play(.cancel)
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
        onInventoryChange?()
    }

    func clearLastIssue() {
        guard lastIssue != nil else { return }
        lastIssue = nil
        onInventoryChange?()
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
        // Give quick visual feedback if the selection check takes more than a blink.
        armingReveal?.cancel()
        armingReveal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled, let self, self.run == id, self.state == .arming else { return }
            self.hud.reset()
            self.hud.target = intent == .translate ? self.targetLanguage : nil
            self.hud.show(.arming)
        }
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
            armingReveal?.cancel()
            early?.stop()
            guard id == run else { return }
            await rework(selection, id)
            return
        }
        armingReveal?.cancel()
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
                    setupProblem("Murmur can't hear you", "Allow the microphone to dictate.", page: .general)
                    return
                }
            case .denied, .restricted:
                setupProblem("Murmur can't hear you", "Allow the microphone in System Settings.", page: .general)
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
        let c = AudioCapture(preferredDeviceUID: settings.preferredMicUID)
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

        // If the user finished a hold-to-talk gesture while arming was still wrapping up,
        // stop cleanly right after the stream starts so their audio still transcribes.
        if pendingHoldStopRun == id {
            pendingHoldStopRun = nil
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard let self, self.run == id, self.state == .listening else { return }
                self.stopListening()
            }
            return
        }

        // A shortcut pressed by accident, or a dictation forgotten, would
        // otherwise run up the Doubao bill until the length limit.
        let started = Date()
        quietLimit = settings.quietStop
        silence = quietLimit > 0 ? SilenceWatch(limit: quietLimit, start: started) : nil
        autoStop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self, self.run == id, self.state == .listening else { return }
                let now = Date()
                if now.timeIntervalSince(started) >= Self.maxRecording {
                    self.stopListening(.limit)
                    return
                }
                if let silence = self.silence {
                    if silence.expired(at: now) {
                        self.stopListening(.quiet)
                        return
                    }
                    let remaining = silence.remaining(at: now)
                    let warnWindow = min(15.0, max(5.0, self.quietLimit / 3.0))
                    if self.hud.link == .live, remaining <= warnWindow, remaining > 0 {
                        self.hud.quietCountdown = Int(ceil(remaining))
                    } else if self.hud.quietCountdown != nil {
                        self.hud.quietCountdown = nil
                    }
                }
            }
        }
    }

    /// Why listening ended, when it wasn't the user's choice.
    private enum StopReason { case user, limit, quiet, microphoneLost }

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
        silence = nil
        holdSessionRun = nil
        pendingHoldStopRun = nil
        pressStartedAt = nil
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
            onInventoryChange?()
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
        if state == .listening {
            silence?.heard(text)
            if hud.quietCountdown != nil { hud.quietCountdown = nil }
        }
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
            silence?.connected(true)
            hud.link = .live
            if transcribing { hud.show(.transcribing(retry: 0)) }
        case .reconnecting(let attempt, _):
            silence?.connected(false)
            if hud.quietCountdown != nil { hud.quietCountdown = nil }
            if state == .listening { hud.link = .reconnecting } else if transcribing { hud.show(.transcribing(retry: attempt)) }
        case .unavailable:
            silence?.connected(false)
            if hud.quietCountdown != nil { hud.quietCountdown = nil }
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
        let raw = PolishPrompt.stripStrikethroughWrapper(
            outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if raw.isEmpty {
            forgetSaved()
            end(.notice(.init(tone: .info, title: reason == .quiet ? "Stopped listening" : "No speech detected",
                              detail: reason == .quiet ? "Nothing was heard for \(Self.spoken(quietLimit))." : nil)))
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
        let restoreClipboard = settings.restoreClipboard
        let pasted = await TextBridge.paste(text, allowPointerFallback: true, restoreClipboard: restoreClipboard)
        // A recording transcribed again was counted, if at all, the first time.
        if !again {
            UsageStore.shared.add(UsageRecord(kind: .dictation, audioSeconds: outcome.seconds, text: text, polish: polish,
                                              waitSeconds: Date().timeIntervalSince(stoppedAt), attempts: attempts,
                                              translated: translated))
        }
        // Only words that are all in let the recording go.
        if outcome.isComplete { forgetSaved() }
        let missing = outcome.isComplete ? nil : "The last \(Self.duration(outcome.unconfirmedSeconds)) is missing"
        let doneTitle: String = {
            if restoreClipboard {
                return translated ? "Translated and inserted" : "Inserted"
            }
            return translated ? "Translated, inserted and copied" : "Inserted and copied"
        }()

        switch pasted {
        case .copied(let why):
            let title = translated ? "Translation copied to the clipboard" : "Copied to the clipboard"
            let page: Page? = why.contains("General page") ? .general : nil
            if let missing {
                let detail = "\(missing). \(Self.savedNote)"
                Cue.play(.problem)
                recordIssue(title, detail, page: page)
                end(.notice(.init(tone: .warning, title: title, detail: detail)))
            } else if reason == .quiet {
                let detail = "\(quietNote) \(why)"
                recordIssue(title, detail, page: page)
                end(.notice(.init(tone: .warning, title: title, detail: detail)))
            } else {
                recordIssue(title, why, page: page)
                end(.notice(.init(tone: .warning, title: title, detail: why)))
            }
        case .pasted:
            if let missing {
                let title = "Inserted, but \(missing.prefix(1).lowercased() + missing.dropFirst())"
                let detail = "\(Self.savedNote)\(outcome.problem.map { " Doubao: \($0)" } ?? "")"
                Cue.play(.problem)
                recordIssue(title, detail, page: nil)
                end(.notice(.init(tone: .warning, title: title, detail: detail)))
            } else if let polishProblem {
                let title = intent == .translate ? "Inserted as heard, untranslated" : "Inserted without polishing"
                Cue.play(.problem)
                recordIssue(title, polishProblem, page: .polish)
                end(.notice(.init(tone: .warning, title: title, detail: polishProblem)))
            } else if let translateProblem {
                let title = "Inserted without translating"
                Cue.play(.problem)
                recordIssue(title, translateProblem, page: .polish)
                end(.notice(.init(tone: .warning, title: title, detail: translateProblem)))
            } else if reason == .limit {
                lastIssue = nil
                end(.notice(.init(tone: .info, title: doneTitle,
                                  detail: "Dictations stop at \(Int(Self.maxRecording / 60)) minutes. Press \(settings.shortcut.display) to go on.")))
            } else if reason == .quiet {
                lastIssue = nil
                end(.notice(.init(tone: .info, title: doneTitle, detail: quietNote)))
            } else if reason == .microphoneLost {
                let detail = "The microphone went away, so the dictation stopped there."
                Cue.play(.problem)
                recordIssue(doneTitle, detail, page: .speech)
                end(.notice(.init(tone: .warning, title: doneTitle, detail: detail)))
            } else {
                lastIssue = nil
                end(.done(doneTitle))
            }
        }
    }

    /// How a saved recording is found again.
    private static let savedNote = "The recording is saved: Transcribe Again from the menu bar."

    /// Why a dictation ended without the shortcut.
    private var quietNote: String {
        "Stopped listening after \(Self.spoken(quietLimit)) without new words."
    }

    /// "30 seconds", "1 minute", "2 minutes".
    static func spoken(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s <= 0 { return "Never" }
        if s < 60 { return "\(s) seconds" }
        if s % 60 == 0 { return s == 60 ? "1 minute" : "\(s / 60) minutes" }
        return String(format: "%d:%02d minutes", s / 60, s % 60)
    }

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
        onInventoryChange?()
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
            lastIssue = nil
            end(.done(translating ? "Already in \(language)" : "Already reads well"))
            return
        }
        guard TextBridge.isStillSelected(selection) else {
            Clipboard.put(out.text)
            UsageStore.shared.add(record)
            let title = translating ? "Translation copied" : "Refined text copied"
            let detail = "The selection changed, so Murmur left it alone. Paste with ⌘V."
            recordIssue(title, detail, page: nil)
            end(.notice(.init(tone: .warning, title: title, detail: detail)))
            return
        }
        let restoreClipboard = settings.restoreClipboard
        // Never click an unrelated text box under the pointer during a selection rewrite.
        let pasted = await TextBridge.paste(out.text, allowPointerFallback: false, restoreClipboard: restoreClipboard)
        UsageStore.shared.add(record)
        switch pasted {
        case .pasted:
            lastIssue = nil
            let title: String
            if restoreClipboard {
                title = translating ? "Translated and replaced" : "Replaced"
            } else {
                title = translating ? "Translated, replaced and copied" : "Replaced and copied"
            }
            end(.done(title))
        case .copied(let why):
            if why.contains("isn't editable") {
                // Translating or refining read-only text (webpage, PDF, received message):
                // copying to clipboard is the clean expected result.
                lastIssue = nil
                end(.done(translating ? "Translation copied" : "Refined text copied"))
            } else {
                let page: Page? = why.contains("General page") ? .general : nil
                recordIssue("Copied to the clipboard", why, page: page)
                end(.notice(.init(tone: .warning, title: "Copied to the clipboard", detail: why)))
            }
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
                                       instructions: settings.prompt, input: text, source: source,
                                       vocabulary: settings.vocabularyTerms) { progress in
            DispatchQueue.main.async { MainActor.assumeIsolated { hud.apply(progress, input: text) } }
        }
    }

    /// The same model and timeout as polishing, with the translation prompt.
    private func translateText(_ text: String) async throws -> PolishOutput {
        let client = settings.openRouterClient()
        let model = settings.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let hud = self.hud
        return try await client.translate(model: model, info: settings.modelInfo, instructions: settings.translatePrompt,
                                          input: text, language: targetLanguage) { progress in
            DispatchQueue.main.async { MainActor.assumeIsolated { hud.apply(progress, input: text) } }
        }
    }

    private func recordIssue(_ title: String, _ detail: String?, page: Page?) {
        lastIssue = LastIssue(title: title, detail: detail, date: Date(), page: page)
    }

    private func end(_ mode: HUDModel.Mode) {
        armingReveal?.cancel()
        armingReveal = nil
        autoStop?.cancel()
        writer?.close()
        writer = nil
        saved = nil
        transcriber = nil
        capture = nil
        hud.finish(mode)
        state = .idle
        onInventoryChange?()
    }

    private func problem(_ title: String, _ detail: String?, page: Page? = nil) {
        Cue.play(.problem)
        recordIssue(title, detail, page: page)
        end(.notice(.init(tone: .error, title: title, detail: detail)))
    }

    private func setupProblem(_ title: String, _ detail: String, page: Page) {
        problem(title, detail, page: page)
        openSettings?(page)
    }
}
