import Foundation
import Observation
import MurmurCore

/// What the floating capsule shows.
@MainActor @Observable
final class HUDModel {
    /// The three stages of Murmur's chained pipeline.
    enum Stage: String, Hashable, Identifiable, CaseIterable {
        case speech, polish, translate
        var id: String { rawValue }
    }

    /// Live progression along the active session's chain (e.g. Speech → Polish → English).
    struct Pipeline: Hashable {
        var stages: [Stage]
        var active: Stage?
        var completed: Set<Stage> = []
        var skipped: Set<Stage> = []
        var targetLanguage: String?

        func label(for stage: Stage) -> String {
            switch stage {
            case .speech: return "Speech"
            case .polish: return "Polish"
            case .translate: return targetLanguage.map { TranslationLanguages.native($0) } ?? "Translate"
            }
        }
    }

    enum Mode: Hashable {
        /// Waiting briefly for selection probe before listening begins.
        case arming
        case listening
        /// Waiting for Doubao's complete text; `retry` counts connections
        /// in a row that failed.
        case transcribing(retry: Int)
        /// The model is at work: polishing a dictation, refining a
        /// selection, or translating either.
        case model(Job, retry: Int, thinking: Bool)
        /// Completed cleanly, with an optional concise payoff metric (e.g. "142 chars · 3.1× faster").
        case done(String, detail: String? = nil)
        case notice(Notice)
        case cancelled

        var isResult: Bool {
            switch self {
            case .done, .notice, .cancelled: return true
            case .arming, .listening, .transcribing, .model: return false
            }
        }
    }

    enum Job: Hashable {
        case polish, refine
        /// Into the named language.
        case translate(String)
    }

    /// The stream to Doubao, as shown while listening.
    enum Link: Equatable {
        case live
        /// Dropped; a new connection is on its way. Speaking can go on.
        case reconnecting
        /// Doubao refused; the recording goes on, to transcribe later.
        case recordingOnly
    }

    struct Notice: Hashable {
        enum Tone: Hashable { case info, warning, error }
        var tone: Tone
        var title: String
        var detail: String?
    }

    /// nil: hidden.
    var mode: Mode? {
        didSet {
            guard mode != oldValue else { return }
            resultOrigin = mode?.isResult == true ? oldValue : nil
            onModeChange?(oldValue, mode)
        }
    }
    /// The session content that fades as a result appears.
    private(set) var resultOrigin: Mode?
    /// Active chained pipeline state for the current session; nil when hidden or single-step notice.
    var pipeline: Pipeline?
    /// Live words: Doubao's partial text, then the model's answer as it streams.
    var liveText = ""
    /// The text the model is working on, shown dimmed until its answer starts.
    var preview = ""
    var startedAt = Date()
    /// The language a translating session will end in; nil when it won't translate.
    var target: String?
    var link = Link.live
    /// Set briefly after a first Esc press on a substantial recording.
    var escapeConfirm = false
    /// Countdown seconds shown in the final moments before quiet auto-stop triggers.
    var quietCountdown: Int?
    /// Increments to pulse the status icon for a busy shortcut or an error.
    private(set) var attentionPulses = 0

    /// Loudness for the waveform, read every frame (not observed, to keep
    /// the rest of the capsule from re-rendering 50 times a second).
    @ObservationIgnored var level: Float = 0
    @ObservationIgnored var onModeChange: ((Mode?, Mode?) -> Void)?
    @ObservationIgnored private var dismissal: Task<Void, Never>?
    @ObservationIgnored private var escapeReset: Task<Void, Never>?

    func reset() {
        dismissal?.cancel()
        clearEscapeConfirm()
        pipeline = nil
        liveText = ""
        preview = ""
        target = nil
        link = .live
        quietCountdown = nil
        level = 0
        startedAt = Date()
    }

    func startListening(translatingTo target: String? = nil, polishEnabled: Bool? = nil) {
        reset()
        self.target = target
        let polish = polishEnabled ?? AppSettings.shared.polishReady
        var stages: [Stage] = [.speech]
        if polish { stages.append(.polish) }
        if target != nil { stages.append(.translate) }
        pipeline = Pipeline(stages: stages, active: .speech, targetLanguage: target)
        mode = .listening
    }

    func advancePipeline(completed stage: Stage, next: Stage?) {
        guard var p = pipeline else { return }
        p.completed.insert(stage)
        p.active = next
        pipeline = p
    }

    func skipPipelineStage(_ stage: Stage, next: Stage? = nil) {
        guard var p = pipeline else { return }
        p.skipped.insert(stage)
        p.active = next
        pipeline = p
    }

    func completePipeline() {
        guard var p = pipeline else { return }
        if let active = p.active { p.completed.insert(active) }
        p.active = nil
        pipeline = p
    }

    func show(_ mode: Mode) {
        dismissal?.cancel()
        if mode != .listening {
            clearEscapeConfirm()
            quietCountdown = nil
        }
        if case .model(let job, _, _) = mode, job != currentJob { waitingSince = Date() }
        self.mode = mode
    }

    /// When the model was first asked for the current job, for the wait
    /// shown on long answers.
    var waitingSince = Date()

    private var currentJob: Job? {
        if case .model(let job, _, _) = mode { return job }
        return nil
    }

    func push(_ levels: [Float]) {
        if let peak = levels.max() { level = peak }
    }

    func armEscapeConfirm() {
        escapeReset?.cancel()
        escapeConfirm = true
        escapeReset = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.escapeConfirm = false
        }
    }

    func clearEscapeConfirm() {
        escapeReset?.cancel()
        escapeReset = nil
        if escapeConfirm { escapeConfirm = false }
    }

    /// Shows a last state, then hides after a moment fitted to it.
    func finish(_ mode: Mode) {
        dismissal?.cancel()
        clearEscapeConfirm()
        quietCountdown = nil
        if case .done = mode { completePipeline() }
        self.mode = mode
        if case .notice(let n) = mode, n.tone == .error { nudge() }
        let hold: Double
        switch mode {
        case .done(_, let detail): hold = detail == nil ? 1.15 : 1.75
        case .cancelled: hold = 0.58
        case .notice(let n): hold = n.detail == nil ? 2.4 : ((n.detail?.count ?? 0) > 64 ? 6.2 : 4.2)
        default: hold = 1.5
        }
        dismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        dismissal?.cancel()
        clearEscapeConfirm()
        quietCountdown = nil
        mode = nil
        level = 0
    }

    func nudge() { attentionPulses += 1 }

    func apply(_ progress: PolishProgress, input: String = "") {
        guard case .model(let job, let retry, let thinking) = mode else { return }
        switch progress {
        case .attempt:
            break
        case .thinking:
            if !thinking { mode = .model(job, retry: retry, thinking: true) }
        case .text(let t):
            let cleaned = PolishPrompt.clean(t, input: input)
            if !cleaned.isEmpty {
                liveText = cleaned
                if thinking { mode = .model(job, retry: retry, thinking: false) }
            }
        case .retrying(let next, _):
            liveText = ""
            mode = .model(job, retry: next, thinking: false)
        }
    }
}
