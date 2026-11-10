import Foundation

/// Notices when a dictation has gone quiet, so one started by accident, or
/// left running and forgotten, doesn't keep recognition (and its bill) going.
///
/// Quiet means no new words from the recognizer, whether nothing was said
/// at all or the speaker has finished. Only time while the recognizer is
/// connected counts: while it reconnects, nothing is billed, and words
/// already spoken may still be on their way.
public struct SilenceWatch: Sendable {
    /// Two minutes: well past a pause for thought, short of a real bill.
    public static let defaultLimit: TimeInterval = 120

    /// Seconds of quiet that end a dictation.
    public let limit: TimeInterval
    private var text = ""
    /// Quiet counted before the connection last dropped.
    private var banked: TimeInterval = 0
    /// When the current connected, quiet stretch began; nil while not connected.
    private var since: Date?

    public init(limit: TimeInterval = defaultLimit, start: Date = Date()) {
        self.limit = limit
        since = start
    }

    /// The recognizer's text so far. Anything new starts the quiet over.
    public mutating func heard(_ text: String, at now: Date = Date()) {
        guard text != self.text else { return }
        self.text = text
        banked = 0
        if since != nil { since = now }
    }

    /// Whether the recognizer is connected. Quiet is counted only while it is.
    public mutating func connected(_ live: Bool, at now: Date = Date()) {
        if live {
            if since == nil { since = now }
        } else if let started = since {
            banked += max(0, now.timeIntervalSince(started))
            since = nil
        }
    }

    /// Seconds of quiet so far.
    public func quiet(at now: Date = Date()) -> TimeInterval {
        banked + (since.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// Quiet for long enough that the dictation should end.
    public func expired(at now: Date = Date()) -> Bool { quiet(at: now) >= limit }
}
