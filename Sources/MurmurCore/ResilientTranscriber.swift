import Foundation

/// Streams a recording to Doubao while it is made and gets the complete
/// text once it ends, over a connection that may fail at any moment.
///
/// - The recording is kept whole, so the network never costs audio.
/// - When the connection drops, the sentences Doubao has confirmed are kept.
///   A new connection opens at once and is sent only the audio after them,
///   faster than real time until it catches up; then it carries on live.
///   Nothing confirmed is recognised (or billed) twice.
/// - While the user is still speaking, it never stops trying. Once they
///   stop, a few attempts in a row that confirm nothing end it. The result
///   is then everything confirmed plus the last words still in progress,
///   and says how much audio at the end Doubao never confirmed.
/// - Only errors no new connection can fix (a refused key, an unopened
///   service) stop it early, with the same result.
public final class ResilientTranscriber: @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        /// Connected and streaming.
        case live
        /// The connection failed; another follows. `attempt` counts tries
        /// in a row that confirmed nothing.
        case reconnecting(attempt: Int, reason: String)
        /// Doubao refused in a way no new connection can fix (a key, the
        /// service, the quota). The recording carries on; nothing more is
        /// transcribed.
        case unavailable(reason: String)
    }

    public struct Outcome: Sendable, Equatable {
        public var text: String
        /// Seconds recorded.
        public var seconds: Double
        /// Seconds at the end that Doubao never confirmed, because it
        /// couldn't be reached. Zero when the text is complete.
        public var unconfirmedSeconds: Double
        /// Connections opened again after one failed.
        public var reconnects: Int
        /// Why the text is incomplete, when it is.
        public var problem: String?

        public var isComplete: Bool { unconfirmedSeconds == 0 }

        public init(text: String, seconds: Double, unconfirmedSeconds: Double = 0, reconnects: Int = 0,
                    problem: String? = nil) {
            self.text = text
            self.seconds = seconds
            self.unconfirmedSeconds = unconfirmedSeconds
            self.reconnects = reconnects
            self.problem = problem
        }
    }

    public struct Tuning: Sendable {
        public var openTimeout: TimeInterval = 8
        /// Pauses before each new connection; the last repeats.
        public var backoff: [TimeInterval] = [0.3, 1, 2, 3, 5]
        /// After the user stops: tries in a row that confirm nothing before
        /// settling for what was confirmed.
        public var attemptsAfterStop = 5
        /// While catching up: audio per step, and the pause between steps
        /// (about ten times faster than real time).
        public var catchUpBytes = PCMTape.bytesPerSecond
        public var catchUpPause: TimeInterval = 0.1
        public init() {}
    }

    private let credentials: DoubaoCredentials
    private let tape: PCMTape
    private let tuning: Tuning
    private let onText: @Sendable (String) -> Void
    private let onStatus: @Sendable (Status) -> Void

    private let lock = NSLock()
    private var current: DoubaoSession?
    private var pump: Task<Result<Outcome, SpeechError>, Never>?
    private let stopped = Flag()
    private let cancelled = Flag()

    public init(credentials: DoubaoCredentials, tape: PCMTape, tuning: Tuning = Tuning(),
                onText: @escaping @Sendable (String) -> Void = { _ in },
                onStatus: @escaping @Sendable (Status) -> Void = { _ in }) {
        self.credentials = credentials
        self.tape = tape
        self.tuning = tuning
        self.onText = onText
        self.onStatus = onStatus
    }

    public func start() {
        lock.withLock {
            guard pump == nil else { return }
            pump = Task.detached(priority: .userInitiated) { [self] in await run() }
        }
    }

    /// The recording has ended: sends the rest and waits for the complete
    /// text, or for what could be confirmed.
    public func finish() async throws -> Outcome {
        stopped.set()
        start()
        guard let pump = lock.withLock({ pump }) else { throw SpeechError(.cancelled, "Cancelled.") }
        return try await pump.value.get()
    }

    public func cancel() {
        cancelled.set()
        stopped.set()
        let session = lock.withLock { current }
        session?.cancel()
    }

    // MARK: The loop

    private func run() async -> Result<Outcome, SpeechError> {
        var kept: [String] = []      // confirmed text, connection by connection
        var base = 0                 // where in the recording the current connection's audio starts
        var inProgress = ""          // unconfirmed words after `kept`, from the last connection that had any
        var reconnects = 0
        var failures = 0             // tries in a row that confirmed nothing
        var failuresAfterStop = 0

        while true {
            if cancelled.isSet { return .failure(Self.cancelledError) }
            let prefix = Transcript.join(kept)
            let onText = self.onText
            let session = DoubaoSession(credentials: credentials) { text in onText(Transcript.join([prefix, text])) }
            lock.withLock { current = session }
            var sent = 0
            do {
                try await session.open(timeout: tuning.openTimeout)
                if reconnects > 0 { onStatus(.live) }
                while true {
                    if cancelled.isSet { throw Self.cancelledError }
                    let start = base + sent
                    let available = tape.count
                    if available > start {
                        let behind = available - start
                        let end = start + min(behind, tuning.catchUpBytes)
                        try await session.send(tape.slice(from: start, to: end))
                        sent = end - base
                        if behind > tuning.catchUpBytes { await pause(tuning.catchUpPause) }
                    } else if stopped.isSet {
                        break
                    } else {
                        await pause(0.04)
                    }
                }
                let seconds = Double(sent) / Double(PCMTape.bytesPerSecond)
                let r = try await session.finish(timeout: min(45, 12 + seconds * 0.1))
                return .success(Outcome(text: Transcript.join(kept + [r.text]), seconds: tape.seconds,
                                        unconfirmedSeconds: 0, reconnects: reconnects))
            } catch {
                session.cancel()
                let e = Self.speech(error)
                if cancelled.isSet || e.kind == .cancelled { return .failure(Self.cancelledError) }
                if e.kind == .noSpeech {
                    // Nothing more was said after what is kept.
                    return .success(Outcome(text: prefix, seconds: tape.seconds, unconfirmedSeconds: 0, reconnects: reconnects))
                }

                // Keep what this connection confirmed, and resume right after it.
                let heard = session.latest
                let confirmed = heard.confirmed
                let advance = min(PCMTape.offset(ms: confirmed.endMS), sent)
                if advance > 0 || !confirmed.text.isEmpty {
                    kept.append(confirmed.text)
                    base += advance
                    inProgress = heard.unconfirmedText
                    failures = 0
                    failuresAfterStop = 0
                } else {
                    let words = heard.unconfirmedText
                    if words.count > inProgress.count { inProgress = words }
                    failures += 1
                    if stopped.isSet { failuresAfterStop += 1 }
                }

                if !e.retryable || (stopped.isSet && failuresAfterStop >= tuning.attemptsAfterStop) {
                    if !e.retryable { onStatus(.unavailable(reason: e.message)) }
                    return await settle(kept: kept, inProgress: inProgress, base: base, reconnects: reconnects, error: e)
                }
                reconnects += 1
                onStatus(.reconnecting(attempt: max(1, failures), reason: e.message))
                await pause(tuning.backoff[min(max(failures - 1, 0), tuning.backoff.count - 1)])
            }
        }
    }

    /// The connection can't be had: once the user has stopped (everything
    /// they say until then is still recorded), the result is what was
    /// confirmed, plus the words that were still in progress.
    private func settle(kept: [String], inProgress: String, base: Int, reconnects: Int,
                        error: SpeechError) async -> Result<Outcome, SpeechError> {
        while !stopped.isSet { await pause(0.1) }
        if cancelled.isSet { return .failure(Self.cancelledError) }
        let text = Transcript.join(kept + [inProgress])
        guard !text.isEmpty else { return .failure(error) }
        let missing = Double(max(0, tape.count - base)) / Double(PCMTape.bytesPerSecond)
        let unconfirmed = inProgress.isEmpty && missing < 0.3 ? 0 : max(missing, 0.1)
        return .success(Outcome(text: text, seconds: tape.seconds, unconfirmedSeconds: unconfirmed,
                                reconnects: reconnects, problem: unconfirmed > 0 ? error.message : nil))
    }

    private func pause(_ seconds: TimeInterval) async {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until, !cancelled.isSet {
            try? await Task.sleep(nanoseconds: UInt64(min(0.05, max(0, until.timeIntervalSinceNow)) * 1_000_000_000))
        }
    }

    private static let cancelledError = SpeechError(.cancelled, "Cancelled.")

    private static func speech(_ error: Error) -> SpeechError {
        if let e = error as? SpeechError { return e }
        if error is CancellationError { return cancelledError }
        return SpeechError(.network, error.localizedDescription, retryable: true)
    }
}
