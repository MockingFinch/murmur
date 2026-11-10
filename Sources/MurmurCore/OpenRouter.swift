import Foundation

// MARK: - Models

/// A model as OpenRouter lists it, with what Murmur needs to call it well.
public struct OpenRouterModel: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// USD per million tokens.
    public var inputPrice: Double
    public var outputPrice: Double
    public var contextLength: Int
    public var created: Double
    public var supportsReasoning: Bool
    public var reasoningMandatory: Bool
    public var efforts: [String]

    public init(id: String, name: String, inputPrice: Double = 0, outputPrice: Double = 0, contextLength: Int = 0,
                created: Double = 0, supportsReasoning: Bool = false, reasoningMandatory: Bool = false, efforts: [String] = []) {
        self.id = id
        self.name = name
        self.inputPrice = inputPrice
        self.outputPrice = outputPrice
        self.contextLength = contextLength
        self.created = created
        self.supportsReasoning = supportsReasoning
        self.reasoningMandatory = reasoningMandatory
        self.efforts = efforts
    }

    /// The vendor part of the id, for grouping ("google", "anthropic").
    public var vendor: String { String(id.split(separator: "/").first ?? "") }

    /// Parses `GET /api/v1/models`, keeping models that write text through Chat Completions.
    public static func parseList(_ data: Data) throws -> [OpenRouterModel] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else {
            throw PolishFailure(.badResponse, "The model list was unreadable.")
        }
        func price(_ v: Any?) -> Double {
            if let s = v as? String, let d = Double(s) { return d * 1_000_000 }
            if let n = v as? NSNumber { return n.doubleValue * 1_000_000 }
            return 0
        }
        return items.compactMap { m in
            guard let id = m["id"] as? String, !id.hasSuffix(":batch") else { return nil }
            let arch = m["architecture"] as? [String: Any]
            if let outputs = arch?["output_modalities"] as? [String], !outputs.contains("text") { return nil }
            if let endpoints = m["endpoints"] as? [String], !endpoints.isEmpty,
               !endpoints.contains(where: { $0.hasSuffix("/chat/completions") }) { return nil }
            let pricing = m["pricing"] as? [String: Any]
            let params = m["supported_parameters"] as? [String] ?? []
            let reasoning = m["reasoning"] as? [String: Any]
            return OpenRouterModel(
                id: id,
                name: (m["name"] as? String) ?? id,
                inputPrice: price(pricing?["prompt"]),
                outputPrice: price(pricing?["completion"]),
                contextLength: (m["context_length"] as? NSNumber)?.intValue ?? 0,
                created: (m["created"] as? NSNumber)?.doubleValue ?? 0,
                supportsReasoning: reasoning != nil || params.contains("reasoning"),
                reasoningMandatory: (reasoning?["mandatory"] as? Bool) ?? false,
                efforts: reasoning?["supported_efforts"] as? [String] ?? []
            )
        }
    }
}

// MARK: - Reasoning

/// How much a model may think before it answers. Polishing needs none:
/// thinking only adds seconds, and models that think by default can take
/// a minute over a sentence.
public enum ReasoningSetting: Equatable, Sendable {
    /// Send nothing: the model's own default.
    case omit
    /// `{"enabled": false}`
    case disabled
    /// `{"effort": …}`
    case effort(String)

    public var json: [String: Any]? {
        switch self {
        case .omit: return nil
        case .disabled: return ["enabled": false]
        case .effort(let e): return ["effort": e]
        }
    }

    /// The least thinking `model` allows. Unknown models are asked for none;
    /// if they refuse, the request is sent again without the setting.
    public static func least(for model: OpenRouterModel?) -> ReasoningSetting {
        guard let model else { return .effort("none") }
        guard model.supportsReasoning else { return .omit }
        if !model.reasoningMandatory {
            if model.efforts.isEmpty || model.efforts.contains("none") { return .effort("none") }
            return .disabled
        }
        for e in ["minimal", "low", "medium", "high", "xhigh", "max"] where model.efforts.contains(e) {
            return .effort(e)
        }
        return .effort("low")
    }
}

// MARK: - Errors

public struct PolishFailure: Error, LocalizedError, Sendable, Equatable {
    public enum Kind: Sendable {
        case auth, credits, model, badRequest, reasoningRejected, moderation, rateLimit, server,
             network, offline, timeout, stalled, truncated, empty, badResponse, cancelled
    }

    public var kind: Kind
    public var message: String
    public var retryable: Bool
    public var retryAfter: TimeInterval?
    public var status: Int?

    public init(_ kind: Kind, _ message: String, retryable: Bool = false, retryAfter: TimeInterval? = nil, status: Int? = nil) {
        self.kind = kind
        self.message = message
        self.retryable = retryable
        self.retryAfter = retryAfter
        self.status = status
    }

    public var errorDescription: String? { message }

    /// A non-2xx answer.
    public static func http(status: Int, body: Data, retryAfter: TimeInterval?) -> PolishFailure {
        let detail = errorMessage(body)
        let low = detail.lowercased()
        switch status {
        case 400 where ["reasoning", "effort", "thinking"].contains(where: low.contains):
            return PolishFailure(.reasoningRejected, detail, status: status)
        case 400:
            return PolishFailure(.badRequest, "The model API rejected the request: \(detail)", status: status)
        case 401:
            return PolishFailure(.auth, "The model API didn't accept the API key.", status: status)
        case 402:
            return PolishFailure(.credits, "The model API account is out of credits.", status: status)
        case 403:
            return PolishFailure(.moderation, "The model API refused the text: \(detail)", status: status)
        case 404:
            return PolishFailure(.model, "The model API can't serve this model: \(detail)", status: status)
        case 408:
            return PolishFailure(.timeout, "The model API timed out.", retryable: true, retryAfter: retryAfter, status: status)
        case 429:
            return PolishFailure(.rateLimit, "The model API is rate-limiting requests.", retryable: true, retryAfter: retryAfter, status: status)
        case 500...599:
            return PolishFailure(.server, "The model's provider failed (HTTP \(status)): \(detail)", retryable: true, retryAfter: retryAfter, status: status)
        default:
            return PolishFailure(.server, "The model API returned HTTP \(status): \(detail)", retryable: status >= 500, status: status)
        }
    }

    /// An `error` object inside a stream that had already started.
    static func midStream(_ error: [String: Any]) -> PolishFailure {
        let code = (error["code"] as? NSNumber)?.intValue
        let message = (error["message"] as? String) ?? "unknown error"
        if let code, (400..<500).contains(code), code != 408, code != 429 {
            return PolishFailure(.badRequest, "The provider refused the request: \(message)", status: code)
        }
        return PolishFailure(.server, "The provider failed mid-answer: \(message)", retryable: true, status: code)
    }

    static func errorMessage(_ body: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let e = obj["error"] as? [String: Any] {
                var message = (e["message"] as? String) ?? ""
                if let meta = e["metadata"] as? [String: Any], let provider = meta["provider_name"] as? String {
                    message += " (\(provider))"
                }
                if !message.isEmpty { return message }
            }
            if let s = obj["error"] as? String { return s }
            if let s = obj["message"] as? String { return s }
        }
        let text = String(data: body.prefix(300), encoding: .utf8) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "no details" : text
    }

    /// The whole polish ran out of time; not worth another attempt.
    static func overall(_ seconds: TimeInterval) -> PolishFailure {
        PolishFailure(.timeout, "No complete answer within \(Int(seconds)) seconds.")
    }

    static func from(_ error: Error) -> PolishFailure {
        if let e = error as? PolishFailure { return e }
        if error is CancellationError { return PolishFailure(.cancelled, "Cancelled.") }
        if let url = error as? URLError {
            switch url.code {
            case .cancelled: return PolishFailure(.cancelled, "Cancelled.")
            case .notConnectedToInternet: return PolishFailure(.offline, "You're offline.", retryable: true)
            case .timedOut: return PolishFailure(.timeout, "The connection to the model API timed out.", retryable: true)
            case .cannotFindHost, .dnsLookupFailed:
                return PolishFailure(.network, "Couldn't reach the model API's address (DNS). Check the endpoint, your network or proxy.", retryable: true)
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
                return PolishFailure(.network, "The secure connection to the model API failed. Check your proxy.", retryable: true)
            default:
                return PolishFailure(.network, "The connection to the model API failed: \(url.localizedDescription)", retryable: true)
            }
        }
        return PolishFailure(.network, error.localizedDescription, retryable: true)
    }
}

// MARK: - Client

public enum PolishProgress: Sendable, Equatable {
    /// A request is on its way (1-based).
    case attempt(Int)
    /// The model is thinking before it writes.
    case thinking
    /// The answer so far.
    case text(String)
    /// The last attempt failed; another follows.
    case retrying(next: Int, reason: String)
}

public struct PolishOutput: Sendable, Equatable {
    public var text: String
    public var attempts: Int
    public var servedBy: String?
}

public struct OpenRouterKeyInfo: Sendable, Equatable {
    public var label: String
    public var usage: Double
    public var limit: Double?
    public var isFreeTier: Bool
}

public final class OpenRouterClient: Sendable {
    public static let defaultBase = URL(string: "https://openrouter.ai/api/v1")!

    /// Reads an endpoint as people paste it: trims it, drops a trailing
    /// slash or a full `/chat/completions` path, and wants http(s) and a host.
    public static func endpoint(from text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        for suffix in ["/chat/completions", "/completions"] where t.lowercased().hasSuffix(suffix) {
            t.removeLast(suffix.count)
            break
        }
        while t.hasSuffix("/") { t.removeLast() }
        guard let url = URL(string: t), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// OpenRouter takes a few extra request fields (thinking effort, fastest
    /// provider first); other OpenAI-compatible APIs get the plain request.
    public static func isOpenRouter(_ base: URL) -> Bool {
        guard let host = base.host?.lowercased() else { return false }
        return host == "openrouter.ai" || host.hasSuffix(".openrouter.ai")
    }
    /// Seconds Murmur waits for a polished answer before it gives up.
    public static let defaultTimeout: TimeInterval = 180

    /// One shared session, so the connection a warm-up opens is the one the
    /// answer comes back on. It follows the Mac's proxy settings.
    public static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["X-Title": "Murmur"]
        return URLSession(configuration: config)
    }()

    public struct Tuning: Sendable {
        /// Attempts in all (network errors, overloaded providers, broken streams).
        public var attempts = 3
        /// No byte at all (keep-alives count) for this long: the request is stuck.
        public var idleTimeout: TimeInterval = 20
        /// The longest the whole polish may take, retries included. After it,
        /// the caller falls back to the text it had.
        public var timeout: TimeInterval = OpenRouterClient.defaultTimeout
        /// Waits between attempts.
        public var backoff: [TimeInterval] = [0.5, 1.5, 3]
        public init() {}
    }

    let apiKey: String
    let base: URL
    let session: URLSession
    let tuning: Tuning
    /// Whether to send OpenRouter's extra fields.
    let extras: Bool

    /// - Parameter openRouterExtras: defaults to whether `base` is OpenRouter.
    public init(apiKey: String, base: URL = OpenRouterClient.defaultBase,
                session: URLSession = OpenRouterClient.sharedSession, tuning: Tuning = Tuning(),
                openRouterExtras: Bool? = nil) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.base = base
        self.session = session
        self.tuning = tuning
        self.extras = openRouterExtras ?? Self.isOpenRouter(base)
    }

    private func authorize(_ request: inout URLRequest) {
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
    }

    // MARK: Small requests

    public static func fetchModels(base: URL = defaultBase, session: URLSession = sharedSession) async throws -> [OpenRouterModel] {
        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw PolishFailure.http(status: http.statusCode, body: data, retryAfter: nil)
        }
        return try OpenRouterModel.parseList(data)
    }

    /// Checks the key and reads its usage.
    public func keyInfo() async throws -> OpenRouterKeyInfo {
        var request = URLRequest(url: base.appendingPathComponent("key"))
        authorize(&request)
        request.timeoutInterval = 20
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw PolishFailure.from(error) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw PolishFailure.http(status: http.statusCode, body: data, retryAfter: nil)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any] else {
            throw PolishFailure(.badResponse, "The model API's answer was unreadable.")
        }
        return OpenRouterKeyInfo(label: (d["label"] as? String) ?? "",
                                 usage: (d["usage"] as? NSNumber)?.doubleValue ?? 0,
                                 limit: (d["limit"] as? NSNumber)?.doubleValue,
                                 isFreeTier: (d["is_free_tier"] as? Bool) ?? false)
    }

    /// Opens the connection ahead of time (DNS, TLS, HTTP/2), so the answer
    /// does not pay for it after the user stops speaking.
    public func warmUp() {
        var request = URLRequest(url: base.appendingPathComponent(extras ? "key" : "models"))
        authorize(&request)
        request.timeoutInterval = 15
        session.dataTask(with: request).resume()
    }

    // MARK: Polishing

    /// Polishes `input` with `instructions`: streams the answer, watches the
    /// stream for stalls, and tries again on failures that may pass.
    public func polish(model: String, info: OpenRouterModel?, instructions: String, input: String,
                       source: PolishPrompt.Source,
                       progress: @escaping @Sendable (PolishProgress) -> Void) async throws -> PolishOutput {
        let (system, user) = PolishPrompt.messages(instructions: instructions, input: input, source: source)
        return try await answer(model: model, info: info, system: system, user: user, input: input, progress: progress)
    }

    /// Translates `input` into `language` with `instructions`, with the same
    /// streaming, stall watch, deadline and retries as polishing.
    public func translate(model: String, info: OpenRouterModel?, instructions: String, input: String,
                          language: String,
                          progress: @escaping @Sendable (PolishProgress) -> Void) async throws -> PolishOutput {
        let (system, user) = TranslatePrompt.messages(instructions: instructions, input: input, language: language)
        return try await answer(model: model, info: info, system: system, user: user, input: input, progress: progress)
    }

    /// One complete answer to `system` and `user` about `input`.
    private func answer(model: String, info: OpenRouterModel?, system: String, user: String, input: String,
                        progress: @escaping @Sendable (PolishProgress) -> Void) async throws -> PolishOutput {
        let chars = input.count
        var reasoning = extras ? ReasoningSetting.least(for: info) : .omit
        let deadline = Date().addingTimeInterval(tuning.timeout)
        let maxTokens = min(32_000, max(2_048, chars * 4 + 2_048))

        var attempt = 0
        var freeRetryUsed = false
        while true {
            attempt += 1
            progress(.attempt(attempt))
            let body = Self.body(model: model, system: system, user: user, reasoning: reasoning, maxTokens: maxTokens,
                                 openRouter: extras)
            do {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 1 else { throw PolishFailure.overall(tuning.timeout) }
                let (raw, served) = try await streamOnce(body: body, budget: remaining, total: tuning.timeout, progress: progress)
                let text = PolishPrompt.clean(raw, input: input)
                if text.isEmpty, TextMetrics.visibleCharacters(input) > 8 {
                    throw PolishFailure(.empty, "The model returned nothing.", retryable: true)
                }
                return PolishOutput(text: text, attempts: attempt, servedBy: served)
            } catch {
                var failure = PolishFailure.from(error)
                if Task.isCancelled { failure = PolishFailure(.cancelled, "Cancelled.") }
                if failure.kind == .cancelled { throw failure }
                // A model that will not take the reasoning setting: ask again without it, once, for free.
                if failure.kind == .reasoningRejected, reasoning != .omit, !freeRetryUsed {
                    reasoning = .omit
                    freeRetryUsed = true
                    attempt -= 1
                    continue
                }
                if failure.kind == .reasoningRejected {
                    failure = PolishFailure(.badRequest, "The model API rejected the request: \(failure.message)", status: failure.status)
                }
                guard failure.retryable, attempt < tuning.attempts else { throw failure }
                let planned = tuning.backoff[min(attempt - 1, tuning.backoff.count - 1)]
                let wait = min(max(planned, failure.retryAfter ?? 0), 8) * Double.random(in: 0.85...1.15)
                // Another try only if it would have a fair chance before the deadline.
                guard deadline.timeIntervalSinceNow - wait > min(10, tuning.timeout / 4) else { throw failure }
                progress(.retrying(next: attempt + 1, reason: failure.message))
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                if Task.isCancelled { throw PolishFailure(.cancelled, "Cancelled.") }
            }
        }
    }

    static func body(model: String, system: String, user: String, reasoning: ReasoningSetting, maxTokens: Int,
                     openRouter: Bool = true) -> Data {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "stream": true,
            "temperature": 0.3,
            "max_tokens": maxTokens,
        ]
        if openRouter {
            // Interactive use: prefer the provider that answers first; others still back it up.
            body["provider"] = ["sort": "latency", "allow_fallbacks": true]
            if let r = reasoning.json { body["reasoning"] = r }
        }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// One streamed request, raced against a watchdog: any byte (keep-alive
    /// comments included) proves the request alive; silence for
    /// `idleTimeout`, or reaching the overall deadline, ends it.
    private func streamOnce(body: Data, budget: TimeInterval, total: TimeInterval,
                            progress: @escaping @Sendable (PolishProgress) -> Void) async throws -> (String, String?) {
        let activity = Activity()
        let idle = tuning.idleTimeout
        return try await withThrowingTaskGroup(of: (String, String?).self) { group in
            group.addTask { try await self.read(body: body, activity: activity, progress: progress) }
            group.addTask {
                let start = Date()
                while true {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    let now = Date()
                    if now.timeIntervalSince(start) > budget { throw PolishFailure.overall(total) }
                    if now.timeIntervalSince(activity.last) > idle {
                        throw PolishFailure(.stalled, "The model API went silent for \(Int(idle)) seconds.", retryable: true)
                    }
                }
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw PolishFailure(.network, "No answer.", retryable: true) }
            return first
        }
    }

    private func read(body: Data, activity: Activity,
                      progress: @escaping @Sendable (PolishProgress) -> Void) async throws -> (String, String?) {
        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        authorize(&request)
        request.timeoutInterval = tuning.idleTimeout + 10

        let (bytes, response) = try await session.bytes(for: request)
        activity.touch()
        guard let http = response as? HTTPURLResponse else {
            throw PolishFailure(.badResponse, "The model API's answer was not HTTP.", retryable: true)
        }
        if http.statusCode != 200 {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 64 * 1024 { break }
            }
            throw PolishFailure.http(status: http.statusCode, body: data, retryAfter: Self.retryAfter(http))
        }

        var parser = SSEChunkParser()
        var thinkingReported = false
        for try await line in bytes.lines {
            activity.touch()
            switch try parser.consume(line) {
            case .none, .keepAlive:
                continue
            case .done:
                break
            case .chunk(let delta, let thinking):
                if thinking, !thinkingReported {
                    thinkingReported = true
                    progress(.thinking)
                }
                if !delta.isEmpty { progress(.text(parser.content)) }
                continue
            }
            break
        }
        try parser.finish()
        return (parser.content, parser.servedBy)
    }

    static func retryAfter(_ http: HTTPURLResponse) -> TimeInterval? {
        if let ms = http.value(forHTTPHeaderField: "retry-after-ms"), let v = Double(ms) { return v / 1000 }
        if let s = http.value(forHTTPHeaderField: "Retry-After"), let v = Double(s) { return v }
        return nil
    }
}

/// The last moment a stream showed life.
final class Activity: @unchecked Sendable {
    private let lock = NSLock()
    private var stamp = Date()
    func touch() { lock.withLock { stamp = Date() } }
    var last: Date { lock.withLock { stamp } }
}

// MARK: - Server-sent events

/// Reads an OpenAI-style Chat Completions stream, one line at a time.
public struct SSEChunkParser: Sendable {
    public enum Event: Equatable, Sendable {
        case none
        case keepAlive
        case done
        /// New answer text (possibly empty) and whether the model is thinking.
        case chunk(delta: String, thinking: Bool)
    }

    public private(set) var content = ""
    public private(set) var finishReason: String?
    public private(set) var servedBy: String?
    public private(set) var sawDone = false

    public init() {}

    public mutating func consume(_ rawLine: String) throws -> Event {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return .none }
        if line.hasPrefix(":") { return .keepAlive } // ": OPENROUTER PROCESSING"
        guard line.hasPrefix("data:") else { return .none } // event:, id:, retry:
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            sawDone = true
            return .done
        }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PolishFailure(.badResponse, "The model API sent an unreadable chunk.", retryable: true)
        }
        if let error = obj["error"] as? [String: Any] { throw PolishFailure.midStream(error) }
        if let model = obj["model"] as? String, !model.isEmpty { servedBy = model }

        var delta = ""
        var thinking = false
        for choice in obj["choices"] as? [[String: Any]] ?? [] {
            if let d = choice["delta"] as? [String: Any] {
                if let c = d["content"] as? String { delta += c }
                if let r = d["reasoning"] as? String, !r.isEmpty { thinking = true }
                if let r = d["reasoning_details"] as? [Any], !r.isEmpty { thinking = true }
            } else if let m = choice["message"] as? [String: Any], let c = m["content"] as? String {
                delta += c // a server that does not stream
            }
            if let f = choice["finish_reason"] as? String, !f.isEmpty {
                finishReason = f
                if f == "error" {
                    throw PolishFailure(.server, "The provider stopped with an error.", retryable: true)
                }
            }
        }
        content += delta
        return .chunk(delta: delta, thinking: thinking)
    }

    /// Checks how the stream ended.
    public func finish() throws {
        if !sawDone, finishReason == nil {
            throw PolishFailure(.truncated, "The answer was cut off.", retryable: true)
        }
        if finishReason == "length", content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PolishFailure(.truncated, "The model used its whole budget thinking.", retryable: true)
        }
    }
}
