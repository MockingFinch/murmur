import Foundation
import MurmurCore

/// Streams a recording to Doubao while it is made, and gets the complete
/// text once it ends. If the live stream breaks (a network blip, a busy
/// server), nothing is lost: the whole recording is kept and replayed over
/// a fresh connection.
final class LiveTranscriber: @unchecked Sendable {
    struct Outcome {
        var text: String
        /// The text is the last partial result, not a confirmed final one.
        var partial: Bool
        var seconds: Double
    }

    private let credentials: DoubaoCredentials
    private let tape: PCMTape
    private let onPartial: @Sendable (String) -> Void
    private let onRetry: @Sendable (Int) -> Void

    private let lock = NSLock()
    private var live: DoubaoSession?
    private var replaying: DoubaoSession?
    private var liveError: SpeechError?
    private var pump: Task<Void, Never>?
    private let stopped = Flag()
    private let cancelled = Flag()

    init(credentials: DoubaoCredentials, tape: PCMTape,
         onPartial: @escaping @Sendable (String) -> Void,
         onRetry: @escaping @Sendable (Int) -> Void) {
        self.credentials = credentials
        self.tape = tape
        self.onPartial = onPartial
        self.onRetry = onRetry
    }

    func start() {
        pump = Task.detached(priority: .userInitiated) { [self] in await runPump() }
    }

    func cancel() {
        cancelled.set()
        stopped.set()
        pump?.cancel()
        let sessions = lock.withLock { [live, replaying] }
        sessions.forEach { $0?.cancel() }
    }

    /// Ends the stream and waits for the complete text.
    func finish() async throws -> Outcome {
        stopped.set()
        await pump?.value
        let seconds = tape.seconds
        var streamError = lock.withLock { liveError }

        if streamError == nil, let session = lock.withLock({ live }) {
            do {
                let r = try await session.finish(timeout: finalTimeout(seconds))
                return Outcome(text: r.text, partial: false, seconds: seconds)
            } catch {
                streamError = Self.speech(error)
            }
        }
        guard var failure = streamError else {
            throw SpeechError(.protocolError, "The recording never reached Doubao.")
        }
        if failure.kind == .noSpeech { return Outcome(text: "", partial: false, seconds: seconds) }
        if failure.kind == .cancelled || cancelled.isSet { throw SpeechError(.cancelled, "Cancelled.") }

        var best = failure.partialText
        if failure.retryable, seconds > 0.2 {
            for attempt in 1 ... 2 {
                onRetry(attempt)
                do {
                    let r = try await replay(seconds: seconds)
                    return Outcome(text: r.text, partial: false, seconds: seconds)
                } catch {
                    let e = Self.speech(error)
                    if e.kind == .noSpeech { return Outcome(text: "", partial: false, seconds: seconds) }
                    if e.kind == .cancelled || cancelled.isSet { throw SpeechError(.cancelled, "Cancelled.") }
                    if e.partialText.count > best.count { best = e.partialText }
                    failure = e
                    if !e.retryable { break }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
        }
        if !best.isEmpty { return Outcome(text: best, partial: true, seconds: seconds) }
        throw failure
    }

    // MARK: Internals

    private func runPump() async {
        let session = DoubaoSession(credentials: credentials, onPartial: onPartial)
        lock.withLock { live = session }
        do {
            try await session.open(timeout: 8)
        } catch {
            lock.withLock { liveError = Self.speech(error) }
            return
        }
        var sent = 0
        while !cancelled.isSet {
            let available = tape.count
            if available > sent {
                do {
                    try await session.send(tape.slice(from: sent, to: available))
                } catch {
                    lock.withLock { liveError = Self.speech(error) }
                    return
                }
                sent = available
            } else if stopped.isSet {
                return
            } else {
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
    }

    /// Sends the whole recording again, ten times faster than it was spoken.
    private func replay(seconds: Double) async throws -> DoubaoAPI.Result {
        let pcm = tape.all
        let session = DoubaoSession(credentials: credentials, onPartial: onPartial)
        lock.withLock { replaying = session }
        try await session.open(timeout: 8)
        let step = DoubaoAPI.packetBytes * 5
        var offset = 0
        while offset < pcm.count {
            if cancelled.isSet { throw SpeechError(.cancelled, "Cancelled.") }
            let end = min(pcm.count, offset + step)
            try await session.send(pcm.subdata(in: offset ..< end))
            offset = end
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return try await session.finish(timeout: finalTimeout(seconds))
    }

    private func finalTimeout(_ seconds: Double) -> TimeInterval { min(45, 12 + seconds * 0.1) }

    private static func speech(_ error: Error) -> SpeechError {
        if let e = error as? SpeechError { return e }
        if error is CancellationError { return SpeechError(.cancelled, "Cancelled.") }
        return SpeechError(.network, error.localizedDescription, retryable: true)
    }
}
