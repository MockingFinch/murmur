import Foundation

public struct DoubaoCredentials: Sendable, Equatable {
    /// Empty for the new console's single API key; set for the classic App ID + Access Token pair.
    public var appID: String
    /// The API key (new console) or the Access Token (classic console).
    public var token: String
    /// The resource id, which names the model and how it is billed.
    public var resource: String
    /// Overrides the service URL (tests use a local server).
    public var endpoint: URL?

    public init(appID: String = "", token: String, resource: String = DoubaoAPI.defaultResource, endpoint: URL? = nil) {
        self.appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.resource = resource.trimmingCharacters(in: .whitespacesAndNewlines)
        self.endpoint = endpoint
    }

    public var isComplete: Bool { !token.isEmpty && !resource.isEmpty }
}

/// One streaming recognition: open, send PCM as it is recorded, finish,
/// and wait for the complete text.
///
/// `send` and `finish` must be called from one task at a time; the reader
/// runs on its own and reports partial text through `onPartial`.
public final class DoubaoSession: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let secondPass: Bool
    private let onPartial: @Sendable (String) -> Void

    private let lock = NSLock()
    private var sequence: Int32 = 2
    private var pending = Data()
    private var text = ""
    private var durationMS = 0
    private var outcome: Result<DoubaoAPI.Result, SpeechError>?
    private var waiters: [CheckedContinuation<DoubaoAPI.Result, Error>] = []
    private var reader: Task<Void, Never>?
    private var pcmSent = 0

    public init(credentials: DoubaoCredentials,
                urlSession: URLSession = DoubaoSession.defaultURLSession,
                onPartial: @escaping @Sendable (String) -> Void = { _ in }) {
        let url = credentials.endpoint ?? DoubaoAPI.endpoint(for: credentials.resource)
        var request = URLRequest(url: url)
        if credentials.appID.isEmpty {
            request.setValue(credentials.token, forHTTPHeaderField: "X-Api-Key")
        } else {
            request.setValue(credentials.appID, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(credentials.token, forHTTPHeaderField: "X-Api-Access-Key")
        }
        let id = UUID().uuidString.lowercased()
        request.setValue(credentials.resource, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(id, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue(id, forHTTPHeaderField: "X-Api-Connect-Id")
        request.timeoutInterval = 30

        task = urlSession.webSocketTask(with: request)
        task.maximumMessageSize = 4 << 20
        secondPass = !credentials.resource.hasPrefix("volc.bigasr")
        self.onPartial = onPartial
    }

    public static let defaultURLSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    /// The text recognised so far.
    public var latestText: String { lock.withLock { text } }

    /// Seconds of audio sent so far.
    public var secondsSent: Double { lock.withLock { Double(pcmSent) / Double(DoubaoAPI.sampleRate * 2) } }

    // MARK: Lifecycle

    /// Connects, sends the parameters, and waits for the service to accept
    /// them, so bad credentials or an unopened model fail here.
    public func open(timeout: TimeInterval = 10) async throws {
        task.resume()
        let start = DoubaoFrame(kind: .fullClientRequest, flags: .sequence, serialization: .json,
                                compression: .gzip, sequence: 1,
                                payload: DoubaoAPI.startRequest(secondPass: secondPass))
        let bytes = try DoubaoCodec.encode(start)
        let timedOut = Flag()
        do {
            try await withDeadline(timeout, onTimeout: { [task] in
                timedOut.set()
                task.cancel(with: .goingAway, reason: nil)
            }) { [self] in
                try await task.send(.data(bytes))
                let first = try await task.receive()
                _ = try handle(first)
            }
        } catch {
            if timedOut.isSet || error is DeadlineExceeded {
                throw SpeechError(.timeout, "Doubao did not answer within \(Int(timeout)) seconds.", retryable: true)
            }
            throw classify(error)
        }
        reader = Task.detached { [weak self] in await self?.readLoop() }
    }

    /// Sends PCM (16 kHz, 16-bit, mono) in 200 ms packets.
    public func send(_ pcm: Data) async throws {
        if let failure = failure { throw failure }
        var packets: [(Int32, Data)] = []
        lock.withLock {
            pending.append(pcm)
            while pending.count >= DoubaoAPI.packetBytes {
                packets.append((sequence, Data(pending.prefix(DoubaoAPI.packetBytes))))
                pending = Data(pending.dropFirst(DoubaoAPI.packetBytes))
                sequence += 1
            }
        }
        for (seq, packet) in packets {
            try await sendFrame(DoubaoFrame(kind: .audioOnlyRequest, flags: .sequence, compression: .gzip,
                                            sequence: seq, payload: packet))
            lock.withLock { pcmSent += packet.count }
        }
    }

    /// Sends the last packet and waits for the complete text.
    public func finish(timeout: TimeInterval) async throws -> DoubaoAPI.Result {
        if let failure = failure { throw failure }
        let (rest, seq) = lock.withLock { () -> (Data, Int32) in
            let r = pending
            pending = Data()
            return (r, sequence)
        }
        let last = DoubaoFrame(kind: .audioOnlyRequest, flags: [.sequence, .last],
                               compression: rest.isEmpty ? .none : .gzip,
                               sequence: -seq, payload: rest)
        try await sendFrame(last)
        lock.withLock { pcmSent += rest.count }
        do {
            return try await withDeadline(timeout, onTimeout: { [weak self] in
                self?.complete(.failure(SpeechError(.timeout, "Doubao did not return the final text in time.", retryable: true)))
            }) { [self] in try await waitForOutcome() }
        } catch is DeadlineExceeded {
            throw failure ?? SpeechError(.timeout, "Doubao did not return the final text in time.", retryable: true)
        }
    }

    /// Abandons the stream.
    public func cancel() {
        complete(.failure(SpeechError(.cancelled, "Cancelled.")))
        task.cancel(with: .goingAway, reason: nil)
        reader?.cancel()
    }

    // MARK: Internals

    private var failure: SpeechError? {
        lock.withLock {
            if case .failure(let e) = outcome { return e }
            return nil
        }
    }

    private func sendFrame(_ frame: DoubaoFrame) async throws {
        let bytes = try DoubaoCodec.encode(frame)
        do {
            try await task.send(.data(bytes))
        } catch {
            // The reader usually knows why the connection went away.
            if let failure = failure { throw failure }
            throw classify(error)
        }
    }

    private func readLoop() async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                if try handle(message) {
                    let result = lock.withLock { DoubaoAPI.Result(text: text, durationMS: durationMS) }
                    complete(.success(result))
                    task.cancel(with: .normalClosure, reason: nil)
                    return
                }
            } catch {
                complete(.failure(classify(error)))
                return
            }
        }
    }

    /// Reads one server message; true when it was the final one.
    private func handle(_ message: URLSessionWebSocketTask.Message) throws -> Bool {
        guard case .data(let data) = message else {
            throw SpeechError(.protocolError, "Doubao sent an unexpected text message.")
        }
        let frame: DoubaoFrame
        do { frame = try DoubaoCodec.decode(data) } catch {
            throw SpeechError(.protocolError, "Doubao sent an unreadable message (\(error)).")
        }
        switch frame.kind {
        case .serverError:
            throw SpeechError.fromServer(code: frame.errorCode, payload: frame.payload)
        case .serverAck:
            return false
        case .fullServerResponse:
            if let r = DoubaoAPI.parse(frame.payload) {
                var changed: String?
                lock.withLock {
                    if r.durationMS > 0 { durationMS = r.durationMS }
                    // An empty answer keeps the text: the last answer may come without it.
                    if !r.text.isEmpty, r.text != text {
                        text = r.text
                        changed = r.text
                    }
                }
                if let changed { onPartial(changed) }
            }
            return frame.isLast
        default:
            throw SpeechError(.protocolError, "Doubao sent an unexpected message.")
        }
    }

    private func complete(_ result: Result<DoubaoAPI.Result, SpeechError>) {
        let waiting: [CheckedContinuation<DoubaoAPI.Result, Error>] = lock.withLock {
            guard outcome == nil else { return [] }
            var r = result
            if case .failure(var e) = r {
                e.partialText = text
                r = .failure(e)
            }
            outcome = r
            let w = waiters
            waiters = []
            return w
        }
        guard let final = lock.withLock({ outcome }) else { return }
        for w in waiting {
            switch final {
            case .success(let v): w.resume(returning: v)
            case .failure(let e): w.resume(throwing: e)
            }
        }
    }

    private func waitForOutcome() async throws -> DoubaoAPI.Result {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<DoubaoAPI.Result, Error>) in
            let ready: Result<DoubaoAPI.Result, SpeechError>? = lock.withLock {
                if let outcome { return outcome }
                waiters.append(c)
                return nil
            }
            switch ready {
            case .success(let v): c.resume(returning: v)
            case .failure(let e): c.resume(throwing: e)
            case nil: break
            }
        }
    }

    private func classify(_ error: Error) -> SpeechError {
        if let e = error as? SpeechError { return e }
        if let failure = failure { return failure }
        if let http = task.response as? HTTPURLResponse, http.statusCode != 101, http.statusCode >= 300 {
            let message = http.value(forHTTPHeaderField: "X-Api-Message")
            return SpeechError.handshake(status: http.statusCode, message: message)
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet:
                return SpeechError(.network, "You're offline.", retryable: true)
            case .timedOut:
                return SpeechError(.timeout, "The connection to Doubao timed out.", retryable: true)
            case .cannotFindHost, .dnsLookupFailed:
                return SpeechError(.network, "Couldn't reach Doubao (DNS lookup failed).", retryable: true)
            case .cancelled:
                return SpeechError(.cancelled, "Cancelled.")
            default:
                return SpeechError(.network, "The connection to Doubao failed: \(url.localizedDescription)", retryable: true)
            }
        }
        if error is CancellationError { return SpeechError(.cancelled, "Cancelled.") }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == 57 || ns.code == 54 || ns.code == 32 {
            return SpeechError(.network, "The connection to Doubao was lost.", retryable: true)
        }
        return SpeechError(.network, "The connection to Doubao failed: \(error.localizedDescription)", retryable: true)
    }
}

// MARK: - Deadlines

public struct DeadlineExceeded: Error {}

/// A thread-safe boolean that only goes from false to true.
public final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func set() { lock.withLock { value = true } }
    public var isSet: Bool { lock.withLock { value } }
}

/// Runs `operation`, giving up after `seconds`: `onTimeout` then runs, and
/// should unblock the operation (by closing its connection).
public func withDeadline<T: Sendable>(_ seconds: TimeInterval,
                                      onTimeout: @escaping @Sendable () -> Void,
                                      _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            onTimeout()
            throw DeadlineExceeded()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw DeadlineExceeded() }
        return first
    }
}
