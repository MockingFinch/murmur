import Foundation
import Observation
import MurmurCore

/// What the floating capsule shows.
@MainActor @Observable
final class HUDModel {
    enum Mode: Equatable {
        case listening
        /// Waiting for Doubao's complete text; `retry` counts replays.
        case transcribing(retry: Int)
        /// The model is at work on a dictation or a selection.
        case polishing(source: PolishPrompt.Source, retry: Int, thinking: Bool)
        case done(String)
        case notice(Notice)
        case cancelled
    }

    struct Notice: Equatable {
        enum Tone { case info, warning, error }
        var tone: Tone
        var title: String
        var detail: String?
    }

    /// nil: hidden.
    var mode: Mode? {
        didSet { if mode != oldValue { onModeChange?(mode) } }
    }
    /// Live words: Doubao's partial text, then the model's answer as it streams.
    var liveText = ""
    /// The text the model is working on, shown dimmed until its answer starts.
    var preview = ""
    var startedAt = Date()
    /// Bumped to shake the capsule ("busy", errors).
    var shakes = 0

    /// Loudness for the waveform, read every frame (not observed, to keep
    /// the rest of the capsule from re-rendering 50 times a second).
    @ObservationIgnored var level: Float = 0
    @ObservationIgnored var onModeChange: ((Mode?) -> Void)?
    @ObservationIgnored private var dismissal: Task<Void, Never>?

    func reset() {
        dismissal?.cancel()
        liveText = ""
        preview = ""
        level = 0
        startedAt = Date()
    }

    func startListening() {
        reset()
        mode = .listening
    }

    func show(_ mode: Mode) {
        dismissal?.cancel()
        if case .polishing = mode, !isPolishing { waitingSince = Date() }
        self.mode = mode
    }

    /// When the model was first asked, for the wait shown on long answers.
    var waitingSince = Date()

    private var isPolishing: Bool {
        if case .polishing = mode { return true }
        return false
    }

    func push(_ levels: [Float]) {
        if let peak = levels.max() { level = peak }
    }

    /// Shows a last state, then hides after a moment fitted to it.
    func finish(_ mode: Mode) {
        dismissal?.cancel()
        self.mode = mode
        if case .notice(let n) = mode, n.tone == .error { shakes += 1 }
        let hold: Double
        switch mode {
        case .done: hold = 1.1
        case .cancelled: hold = 0.45
        case .notice(let n): hold = n.detail == nil ? 2.2 : 4.2
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
        mode = nil
        level = 0
    }

    func nudge() { shakes += 1 }

    func apply(_ progress: PolishProgress) {
        guard case .polishing(let source, let retry, let thinking) = mode else { return }
        switch progress {
        case .attempt:
            break
        case .thinking:
            if !thinking { mode = .polishing(source: source, retry: retry, thinking: true) }
        case .text(let t):
            liveText = t
            if thinking { mode = .polishing(source: source, retry: retry, thinking: false) }
        case .retrying(let next, _):
            liveText = ""
            mode = .polishing(source: source, retry: next, thinking: false)
        }
    }
}
