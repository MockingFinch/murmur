import Foundation

/// One finished use of Murmur. No text is kept: only its measures.
public struct UsageRecord: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case dictation, refine }
    public enum Polish: String, Codable, Sendable {
        /// The model polished it.
        case polished
        /// Polishing failed; the recognised text went in as it was.
        case fallback
        /// No language model was set up.
        case skipped
    }

    public var id = UUID()
    public var date: Date
    public var kind: Kind
    /// Seconds spoken (0 for a refine).
    public var audioSeconds: Double
    /// Visible characters of what went in.
    public var characters: Int
    public var cjkCharacters: Int
    public var polish: Polish
    /// Seconds from the moment the user stopped (or pressed the shortcut on
    /// a selection) to the text going in.
    public var waitSeconds: Double
    public var attempts: Int
    /// Whether what went in was translated. Absent in records made before
    /// translation existed.
    public var translated: Bool?

    public init(date: Date = Date(), kind: Kind, audioSeconds: Double, text: String, polish: Polish,
                waitSeconds: Double, attempts: Int, translated: Bool = false) {
        self.date = date
        self.kind = kind
        self.audioSeconds = audioSeconds
        self.characters = TextMetrics.visibleCharacters(text)
        self.cjkCharacters = TextMetrics.cjkCharacters(text)
        self.polish = polish
        self.waitSeconds = waitSeconds
        self.attempts = attempts
        self.translated = translated ? true : nil
    }

    /// Minutes the same text would take to type: about 50 CJK characters
    /// or 190 other characters (≈ 38 words) a minute.
    public var typingMinutes: Double {
        Double(cjkCharacters) / 50 + Double(characters - cjkCharacters) / 190
    }

    /// Minutes saved against typing it, never below zero.
    public var minutesSaved: Double {
        let spent = (audioSeconds + waitSeconds) / 60
        return max(0, typingMinutes - spent)
    }
}

public struct UsageSummary: Equatable, Sendable {
    public struct Totals: Equatable, Sendable {
        public var dictations = 0
        public var refines = 0
        /// Dictations and selections that went in translated.
        public var translations = 0
        public var characters = 0
        public var audioSeconds = 0.0
        public var minutesSaved = 0.0
        public var uses: Int { dictations + refines }
    }

    public struct Day: Equatable, Identifiable, Sendable {
        public var id: Date { date }
        public var date: Date
        public var characters: Int
        public var uses: Int
    }

    public var today = Totals()
    public var allTime = Totals()
    /// The last `days` days, oldest first, today last.
    public var days: [Day] = []
    /// Of the uses that asked the model, the share it polished.
    public var polishRate: Double?
    /// Median seconds from stop to text, over the last 50 uses.
    public var medianWait: Double?
    /// Characters per minute of speech.
    public var speakingPace: Double?
    /// Consecutive days with at least one use, ending today (or yesterday).
    public var streak = 0
}

public enum UsageMath {
    public static func summarize(_ records: [UsageRecord], now: Date = Date(), days: Int = 14,
                                 calendar: Calendar = .current) -> UsageSummary {
        var s = UsageSummary()
        let todayStart = calendar.startOfDay(for: now)

        func add(_ r: UsageRecord, to t: inout UsageSummary.Totals) {
            if r.kind == .dictation { t.dictations += 1 } else { t.refines += 1 }
            if r.translated == true { t.translations += 1 }
            t.characters += r.characters
            t.audioSeconds += r.audioSeconds
            t.minutesSaved += r.minutesSaved
        }

        var byDay: [Date: (Int, Int)] = [:]
        for r in records {
            add(r, to: &s.allTime)
            if r.date >= todayStart { add(r, to: &s.today) }
            let d = calendar.startOfDay(for: r.date)
            let v = byDay[d] ?? (0, 0)
            byDay[d] = (v.0 + r.characters, v.1 + 1)
        }

        s.days = (0..<days).reversed().compactMap { back in
            guard let d = calendar.date(byAdding: .day, value: -back, to: todayStart) else { return nil }
            let v = byDay[d] ?? (0, 0)
            return UsageSummary.Day(date: d, characters: v.0, uses: v.1)
        }

        let asked = records.filter { $0.polish != .skipped }
        if !asked.isEmpty {
            s.polishRate = Double(asked.filter { $0.polish == .polished }.count) / Double(asked.count)
        }

        let recent = records.sorted { $0.date > $1.date }.prefix(50).map(\.waitSeconds).sorted()
        if !recent.isEmpty {
            let mid = recent.count / 2
            s.medianWait = recent.count % 2 == 0 ? (recent[mid - 1] + recent[mid]) / 2 : recent[mid]
        }

        let spoken = records.filter { $0.kind == .dictation && $0.audioSeconds > 1 }
        let seconds = spoken.reduce(0) { $0 + $1.audioSeconds }
        if seconds > 10 {
            s.speakingPace = Double(spoken.reduce(0) { $0 + $1.characters }) / (seconds / 60)
        }

        var day = todayStart
        if byDay[day] == nil, let y = calendar.date(byAdding: .day, value: -1, to: day) { day = y }
        while byDay[day] != nil {
            s.streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return s
    }
}
