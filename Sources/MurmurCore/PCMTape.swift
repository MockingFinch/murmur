import Foundation

/// Everything recorded in a session, as 16 kHz 16-bit mono PCM. The live
/// stream reads from it as it grows; a reconnection resends part of it.
public final class PCMTape: @unchecked Sendable {
    public static let bytesPerSecond = DoubaoAPI.sampleRate * 2

    private let lock = NSLock()
    private var data: Data

    public init(_ data: Data = Data()) { self.data = data }

    public func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    public var count: Int { lock.withLock { data.count } }
    public var all: Data { lock.withLock { data } }
    public var seconds: Double { Double(count) / Double(Self.bytesPerSecond) }

    public func slice(from start: Int, to end: Int) -> Data {
        lock.withLock {
            let s = max(0, min(start, data.count))
            let e = max(s, min(end, data.count))
            return data.subdata(in: s ..< e)
        }
    }

    /// The byte offset of a moment in the recording, on a sample boundary.
    public static func offset(ms: Int) -> Int { max(0, ms) * bytesPerSecond / 1000 / 2 * 2 }
}

/// Joins pieces of recognised text: Chinese and Japanese run together,
/// words in Latin script get a space between them.
public enum Transcript {
    public static func join(_ parts: [String]) -> String {
        var out = ""
        for raw in parts {
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if let last = out.unicodeScalars.last, let first = part.unicodeScalars.first,
               needsSpace(after: last), isWordStart(first) {
                out += " "
            }
            out += part
        }
        return out
    }

    private static func needsSpace(after s: Unicode.Scalar) -> Bool {
        isLatinOrDigit(s) || ".,!?;:)\u{201D}\u{2019}".unicodeScalars.contains(s)
    }

    private static func isWordStart(_ s: Unicode.Scalar) -> Bool {
        isLatinOrDigit(s) || "(\u{201C}\u{2018}\"'".unicodeScalars.contains(s)
    }

    private static func isLatinOrDigit(_ s: Unicode.Scalar) -> Bool {
        s.isASCII ? CharacterSet.alphanumerics.contains(s)
            : (0x00C0 ... 0x024F).contains(s.value) || (0x0400 ... 0x04FF).contains(s.value)
    }
}
