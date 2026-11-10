import Foundation

/// Recordings kept on disk until their words are safely in.
///
/// Each dictation is written here while it is spoken, a moment behind the
/// microphone, so a crash, a quit or a network that never comes back
/// doesn't take what was said. Once the text is inserted the recording is
/// deleted. One that couldn't be transcribed in full stays, to transcribe
/// again later, for a week at most.
public final class RecordingStore: @unchecked Sendable {
    public struct Recording: Sendable, Equatable, Identifiable {
        public var id: String
        public var date: Date
        /// The session was to translate as well.
        public var translate: Bool
        public var seconds: Double
    }

    public let directory: URL
    public let keepFor: TimeInterval

    public init(directory: URL, keepFor: TimeInterval = 7 * 24 * 3600) {
        self.directory = directory
        self.keepFor = keepFor
    }

    /// Starts a recording file. nil when the disk can't be written; the
    /// dictation goes ahead without it.
    public func begin(translate: Bool, date: Date = Date()) -> RecordingWriter? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let stamp = Self.stamp.string(from: date)
            let id = "\(stamp)-\(UUID().uuidString.prefix(8).lowercased())"
            let meta = Meta(date: date, translate: translate)
            try JSONEncoder().encode(meta).write(to: metaURL(id), options: .atomic)
            let audio = audioURL(id)
            guard fm.createFile(atPath: audio.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                try? fm.removeItem(at: metaURL(id))
                return nil
            }
            return try RecordingWriter(id: id, url: audio)
        } catch {
            return nil
        }
    }

    /// Every recording on disk, newest first.
    public func all() -> [Recording] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".pcm") }.compactMap { name in
            let id = String(name.dropLast(4))
            let size = (try? FileManager.default.attributesOfItem(atPath: audioURL(id).path)[.size] as? NSNumber)?.intValue ?? 0
            let meta = (try? Data(contentsOf: metaURL(id))).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
            let date = meta?.date ?? (try? FileManager.default.attributesOfItem(atPath: audioURL(id).path)[.creationDate] as? Date) ?? Date()
            return Recording(id: id, date: date, translate: meta?.translate ?? false,
                             seconds: Double(size) / Double(PCMTape.bytesPerSecond))
        }
        .sorted { $0.date > $1.date }
    }

    public func audio(_ id: String) -> Data? { try? Data(contentsOf: audioURL(id)) }

    public func delete(_ id: String) {
        try? FileManager.default.removeItem(at: audioURL(id))
        try? FileManager.default.removeItem(at: metaURL(id))
    }

    /// Deletes recordings older than `keepFor`, and ones too short to hold a word.
    public func prune(now: Date = Date(), except active: String? = nil) {
        for r in all() where r.id != active && (now.timeIntervalSince(r.date) > keepFor || r.seconds < 0.3) {
            delete(r.id)
        }
    }

    // MARK: Files

    private struct Meta: Codable {
        var date: Date
        var translate: Bool
    }

    private func audioURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).pcm") }
    private func metaURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

/// Copies a growing recording to its file, about twice a second.
public final class RecordingWriter: @unchecked Sendable {
    public let id: String
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "murmur.recording", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var tape: PCMTape?
    private var written = 0
    private var closed = false

    init(id: String, url: URL) throws {
        self.id = id
        handle = try FileHandle(forWritingTo: url)
    }

    /// Writes `tape` as it grows, from its start.
    public func follow(_ tape: PCMTape, every interval: TimeInterval = 0.5) {
        queue.sync {
            guard !closed else { return }
            self.tape = tape
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
            t.setEventHandler { [weak self] in self?.flush() }
            t.resume()
            timer = t
        }
    }

    /// Writes what is left and closes the file. The recording stays on
    /// disk until the store deletes it.
    public func close() {
        queue.sync {
            guard !closed else { return }
            timer?.cancel()
            timer = nil
            flush()
            try? handle.synchronize()
            try? handle.close()
            closed = true
        }
    }

    /// Bytes on disk so far.
    public var bytesWritten: Int { queue.sync { written } }

    private func flush() {
        guard !closed, let tape else { return }
        let end = tape.count
        guard end > written else { return }
        do {
            try handle.write(contentsOf: tape.slice(from: written, to: end))
            written = end
        } catch {
            // A full disk: the dictation itself goes on from memory.
            timer?.cancel()
            timer = nil
        }
    }
}
