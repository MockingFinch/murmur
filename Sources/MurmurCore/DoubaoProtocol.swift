import Foundation

// Volcengine's Doubao streaming speech recognition ("SAUC" bigmodel) speaks
// a small binary protocol over a WebSocket. Every message is:
//
//   byte 0  protocol version (high nibble, 1) | header size in 4-byte words (low nibble, 1)
//   byte 1  message type (high nibble)        | type-specific flags (low nibble)
//   byte 2  serialization (high nibble)       | compression (low nibble)
//   byte 3  reserved
//   [int32 sequence]      when flags has .sequence
//   [int32 event]         when flags has .event
//   [uint32 error code]   on error frames
//   uint32 payload size   (absent on server acks)
//   payload
//
// All integers are big-endian.

public struct DoubaoFrame: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case fullClientRequest = 0x1
        case audioOnlyRequest = 0x2
        case fullServerResponse = 0x9
        case serverAck = 0xB
        case serverError = 0xF
    }

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let sequence = Flags(rawValue: 0x1)
        public static let last = Flags(rawValue: 0x2)
        public static let event = Flags(rawValue: 0x4)
    }

    public enum Serialization: UInt8, Sendable { case none = 0, json = 1 }
    public enum Compression: UInt8, Sendable { case none = 0, gzip = 1 }

    public var kind: Kind
    public var flags: Flags = []
    public var serialization: Serialization = .none
    public var compression: Compression = .none
    public var sequence: Int32 = 0
    public var event: Int32 = 0
    public var errorCode: UInt32 = 0
    /// Uncompressed payload.
    public var payload = Data()

    public init(kind: Kind, flags: Flags = [], serialization: Serialization = .none,
                compression: Compression = .none, sequence: Int32 = 0, event: Int32 = 0,
                errorCode: UInt32 = 0, payload: Data = Data()) {
        self.kind = kind
        self.flags = flags
        self.serialization = serialization
        self.compression = compression
        self.sequence = sequence
        self.event = event
        self.errorCode = errorCode
        self.payload = payload
    }

    /// The final message of its direction: the last flag, or a negative sequence.
    public var isLast: Bool {
        flags.contains(.last) || (flags.contains(.sequence) && sequence < 0)
    }
}

public enum DoubaoCodec {
    public struct Malformed: Error, CustomStringConvertible {
        public let description: String
    }

    static let maxFrame = 4 << 20

    public static func encode(_ frame: DoubaoFrame) throws -> Data {
        var body = frame.payload
        if frame.compression == .gzip { body = try Gzip.compress(body) }

        var out = Data(capacity: 16 + body.count)
        out.append(0x11) // version 1, header of one word
        out.append(frame.kind.rawValue << 4 | (frame.flags.rawValue & 0x0F))
        out.append(frame.serialization.rawValue << 4 | (frame.compression.rawValue & 0x0F))
        out.append(0)
        if frame.flags.contains(.sequence) { out.appendBE(UInt32(bitPattern: frame.sequence)) }
        if frame.flags.contains(.event) { out.appendBE(UInt32(bitPattern: frame.event)) }
        if frame.kind == .serverError { out.appendBE(frame.errorCode) }
        if frame.kind != .serverAck { out.appendBE(UInt32(body.count)) }
        out.append(body)
        return out
    }

    public static func decode(_ data: Data) throws -> DoubaoFrame {
        let bytes = [UInt8](data)
        guard bytes.count <= maxFrame else { throw Malformed(description: "frame too large") }
        guard bytes.count >= 4 else { throw Malformed(description: "truncated header") }
        guard bytes[0] >> 4 == 1 else { throw Malformed(description: "unknown protocol version") }
        let headerSize = Int(bytes[0] & 0x0F) * 4
        guard headerSize >= 4, headerSize <= bytes.count else { throw Malformed(description: "bad header size") }
        guard let kind = DoubaoFrame.Kind(rawValue: bytes[1] >> 4) else {
            throw Malformed(description: "unknown message type \(bytes[1] >> 4)")
        }
        guard let compression = DoubaoFrame.Compression(rawValue: bytes[2] & 0x0F) else {
            throw Malformed(description: "unknown compression")
        }
        var frame = DoubaoFrame(kind: kind)
        frame.flags = DoubaoFrame.Flags(rawValue: bytes[1] & 0x0F)
        frame.serialization = DoubaoFrame.Serialization(rawValue: bytes[2] >> 4) ?? .none
        frame.compression = compression

        var cursor = headerSize
        func u32(_ what: String) throws -> UInt32 {
            guard cursor + 4 <= bytes.count else { throw Malformed(description: "truncated \(what)") }
            let v = UInt32(bytes[cursor]) << 24 | UInt32(bytes[cursor + 1]) << 16
                | UInt32(bytes[cursor + 2]) << 8 | UInt32(bytes[cursor + 3])
            cursor += 4
            return v
        }
        if frame.flags.contains(.sequence) { frame.sequence = Int32(bitPattern: try u32("sequence")) }
        if frame.flags.contains(.event) { frame.event = Int32(bitPattern: try u32("event")) }
        if kind == .serverError { frame.errorCode = try u32("error code") }

        var body: [UInt8]
        if kind == .serverAck {
            body = Array(bytes[cursor...])
        } else {
            let size = Int(try u32("payload size"))
            guard cursor + size <= bytes.count else { throw Malformed(description: "truncated payload") }
            body = Array(bytes[cursor ..< cursor + size])
        }
        if compression == .gzip, !body.isEmpty {
            do { body = [UInt8](try Gzip.decompress(Data(body))) } catch {
                throw Malformed(description: "bad gzip payload")
            }
        }
        frame.payload = Data(body)
        return frame
    }
}

extension Data {
    mutating func appendBE(_ v: UInt32) {
        append(UInt8(v >> 24 & 0xFF))
        append(UInt8(v >> 16 & 0xFF))
        append(UInt8(v >> 8 & 0xFF))
        append(UInt8(v & 0xFF))
    }
}

// MARK: - Requests and results

public enum DoubaoAPI {
    /// The optimised duplex stream: partial text only when it changes, and
    /// a second, more accurate pass over each finished sentence.
    public static let asyncEndpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
    /// The original duplex stream, for the 1.0 models.
    public static let duplexEndpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel")!

    public static let sampleRate = 16_000
    /// 200 ms of 16 kHz, 16-bit mono PCM: the packet size the service prefers.
    public static let packetBytes = 6_400

    public struct Resource: Identifiable, Hashable, Sendable {
        public let id: String
        public let title: String
        public let detail: String
        public var isV1: Bool { id.hasPrefix("volc.bigasr") }
    }

    public static let resources: [Resource] = [
        Resource(id: "volc.seedasr.sauc.duration", title: "Doubao ASR 2.0", detail: "Billed by duration"),
        Resource(id: "volc.seedasr.sauc.concurrent", title: "Doubao ASR 2.0", detail: "Billed by concurrency"),
        Resource(id: "volc.bigasr.sauc.duration", title: "Doubao ASR 1.0", detail: "Billed by duration"),
        Resource(id: "volc.bigasr.sauc.concurrent", title: "Doubao ASR 1.0", detail: "Billed by concurrency"),
    ]
    public static let defaultResource = resources[0].id

    public static func endpoint(for resource: String) -> URL {
        resource.hasPrefix("volc.bigasr") ? duplexEndpoint : asyncEndpoint
    }

    /// The full client request that opens a stream.
    public static func startRequest(secondPass: Bool) -> Data {
        var request: [String: Any] = [
            "model_name": "bigmodel",
            "enable_itn": true,
            "enable_punc": true,
            "enable_ddc": true,
            "show_utterances": true,
        ]
        if secondPass { request["enable_nonstream"] = true }
        let body: [String: Any] = [
            "user": ["uid": "murmur"],
            "audio": ["format": "pcm", "codec": "raw", "rate": sampleRate, "bits": 16, "channel": 1],
            "request": request,
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    public struct Result: Equatable, Sendable {
        public var text: String
        public var durationMS: Int
    }

    /// Reads a full server response: the whole text so far, and the audio's length.
    public static func parse(_ payload: Data) -> Result? {
        guard !payload.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        let duration = ((obj["audio_info"] as? [String: Any])?["duration"] as? NSNumber)?.intValue ?? 0

        var results: [[String: Any]] = []
        if let one = obj["result"] as? [String: Any] { results = [one] }
        if let many = obj["result"] as? [[String: Any]] { results = many }

        var text = ""
        for r in results {
            var t = (r["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if t.isEmpty, let utterances = r["utterances"] as? [[String: Any]] {
                t = utterances.compactMap { $0["text"] as? String }.joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            text += t
        }
        return Result(text: text, durationMS: duration)
    }
}

// MARK: - Errors

public struct SpeechError: Error, LocalizedError, Sendable, Equatable {
    public enum Kind: Sendable { case config, auth, quota, network, timeout, server, audio, noSpeech, protocolError, cancelled }

    public var kind: Kind
    public var message: String
    public var retryable: Bool
    public var code: String?
    /// The text recognised before the failure, when there was some.
    public var partialText: String = ""

    public init(_ kind: Kind, _ message: String, retryable: Bool = false, code: String? = nil) {
        self.kind = kind
        self.message = message
        self.retryable = retryable
        self.code = code
    }

    public var errorDescription: String? { message }

    /// Classifies an error frame from the service.
    public static func fromServer(code: UInt32, payload: Data) -> SpeechError {
        var message = ""
        if let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
            message = (obj["message"] as? String) ?? (obj["error"] as? String) ?? ""
        }
        if message.isEmpty { message = String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        let low = message.lowercased()
        let codeText = String(code)

        switch code {
        case 45_000_002:
            return SpeechError(.noSpeech, "No speech was detected.", code: codeText)
        case 45_000_151:
            return SpeechError(.audio, "The service could not read the audio format.", code: codeText)
        case 45_000_081:
            return SpeechError(.network, "The connection stalled while sending audio.", retryable: true, code: codeText)
        case 55_000_031:
            return SpeechError(.server, "Doubao is busy right now.", retryable: true, code: codeText)
        default:
            break
        }
        if code / 100_000 == 550 {
            return SpeechError(.server, "Doubao had an internal error\(message.isEmpty ? "" : ": \(message)").", retryable: true, code: codeText)
        }
        if ["quota", "not granted", "concurren", "rate limit", "too many", "qps", "arrear", "balance", "insufficient", "expired"].contains(where: low.contains) {
            let retry = low.contains("concurren") || low.contains("rate") || low.contains("qps")
            return SpeechError(.quota, "Doubao refused the request: \(message)", retryable: retry, code: codeText)
        }
        if ["auth", "token", "access key", "app key", "appid", "app id", "permission", "forbidden", "unauthorized", "invalid key"].contains(where: low.contains) {
            return SpeechError(.auth, "Doubao did not accept the credentials: \(message)", code: codeText)
        }
        return SpeechError(.protocolError, message.isEmpty ? "Doubao error \(codeText)." : "Doubao error \(codeText): \(message)", code: codeText)
    }

    /// Explains a refused WebSocket handshake.
    public static func handshake(status: Int, message: String?) -> SpeechError {
        let detail = message.map { " (\($0))" } ?? ""
        switch status {
        case 401:
            return SpeechError(.auth, "Doubao did not accept the credentials\(detail). Check the key in Speech settings.", code: "401")
        case 403:
            return SpeechError(.quota, "Doubao refused this model for your account\(detail). Make sure the selected model is enabled in the Volcengine console.", code: "403")
        case 429:
            return SpeechError(.quota, "Doubao is rate-limiting this account\(detail).", retryable: true, code: "429")
        case 500...599:
            return SpeechError(.server, "Doubao returned HTTP \(status)\(detail).", retryable: true, code: String(status))
        default:
            return SpeechError(.network, "Doubao refused the connection (HTTP \(status))\(detail).", retryable: true, code: String(status))
        }
    }
}
