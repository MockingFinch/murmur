import XCTest
@testable import MurmurCore

final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [PolishProgress] = []
    func add(_ e: PolishProgress) { lock.withLock { list.append(e) } }
    var all: [PolishProgress] { lock.withLock { list } }
}

final class OpenRouterNetworkTests: XCTestCase {
    private func fastTuning() -> OpenRouterClient.Tuning {
        var t = OpenRouterClient.Tuning()
        t.idleTimeout = 1
        t.timeout = 10
        t.backoff = [0.05, 0.05, 0.05]
        return t
    }

    private func client(_ server: FakeHTTPServer) -> OpenRouterClient {
        OpenRouterClient(apiKey: "sk-test", base: server.base, session: URLSession(configuration: .ephemeral), tuning: fastTuning(),
                         openRouterExtras: true)
    }

    func testRetriesAfterAnOverloadedProviderAndIgnoresKeepAlives() async throws {
        let server = try FakeHTTPServer { index, _ in
            if index == 1 {
                return [.write(FakeHTTPServer.head(503, "Service Unavailable", contentType: "application/json")),
                        .write(#"{"error":{"code":503,"message":"No provider available"}}"#)]
            }
            return [.write(FakeHTTPServer.head(200, "OK")),
                    .write(": OPENROUTER PROCESSING\n\n"), .wait(0.6),
                    .write(": OPENROUTER PROCESSING\n\n"), .wait(0.6),
                    .write("data: {\"choices\":[{\"delta\":{\"reasoning\":\"...\"}}]}\n\n"),
                    .write(FakeHTTPServer.chunk("这个 API 的 ")), .wait(0.1),
                    .write(FakeHTTPServer.chunk("response 有点慢。", finish: "stop")),
                    .write("data: [DONE]\n\n")]
        }
        let events = Events()
        let out = try await client(server).polish(model: "fake/model", info: nil, instructions: "Rules.",
                                                  input: "这个API，嗯，response有点慢", source: .dictation) { events.add($0) }
        XCTAssertEqual(out.text, "这个 API 的 response 有点慢。")
        XCTAssertEqual(out.attempts, 2)
        XCTAssertEqual(out.servedBy, "fake/model")
        XCTAssertTrue(events.all.contains(.thinking))
        XCTAssertTrue(events.all.contains { if case .retrying(next: 2, _) = $0 { return true }; return false })
        // Keep-alives 0.6 s apart kept a 1 s idle limit from firing.
        XCTAssertEqual(server.requestCount, 2)
    }

    func testAStalledStreamIsAbandonedAndRetried() async throws {
        let server = try FakeHTTPServer { index, _ in
            if index == 1 {
                return [.write(FakeHTTPServer.head(200, "OK")), .write(FakeHTTPServer.chunk("half")), .wait(5)]
            }
            return [.write(FakeHTTPServer.head(200, "OK")), .write(FakeHTTPServer.chunk("Done.", finish: "stop")), .write("data: [DONE]\n\n")]
        }
        let started = Date()
        let out = try await client(server).polish(model: "m", info: nil, instructions: "", input: "done", source: .dictation) { _ in }
        XCTAssertEqual(out.text, "Done.")
        XCTAssertEqual(out.attempts, 2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testTheOverallTimeoutEndsAnAnswerKeptAliveForever() async throws {
        // Keep-alives every 0.3 s: never "stalled", but never finished either.
        let server = try FakeHTTPServer { _, _ in
            [.write(FakeHTTPServer.head(200, "OK"))]
                + Array(repeating: [FakeHTTPServer.Step.write(": OPENROUTER PROCESSING\n\n"), .wait(0.3)], count: 30).flatMap { $0 }
        }
        var tuning = fastTuning()
        tuning.timeout = 2
        let c = OpenRouterClient(apiKey: "sk-test", base: server.base, session: URLSession(configuration: .ephemeral), tuning: tuning)
        let started = Date()
        do {
            _ = try await c.polish(model: "m", info: nil, instructions: "", input: "x", source: .dictation) { _ in }
            XCTFail("expected a timeout")
        } catch let e as PolishFailure {
            XCTAssertEqual(e.kind, .timeout)
            XCTAssertEqual(e.message, "No complete answer within 2 seconds.")
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(elapsed, 1.8)
        XCTAssertLessThan(elapsed, 3)
        XCTAssertEqual(server.requestCount, 1, "no retry once the deadline has passed")
    }

    func testOtherAPIsGetThePlainRequest() async throws {
        let server = try FakeHTTPServer { _, _ in
            [.write(FakeHTTPServer.head(200, "OK")), .write(FakeHTTPServer.chunk("Fine.", finish: "stop")), .write("data: [DONE]\n\n")]
        }
        let c = OpenRouterClient(apiKey: "", base: server.base, session: URLSession(configuration: .ephemeral), tuning: fastTuning())
        let out = try await c.polish(model: "qwen3:8b", info: nil, instructions: "", input: "fine", source: .dictation) { _ in }
        XCTAssertEqual(out.text, "Fine.")
        let request = server.allRequests[0]
        XCTAssertTrue(request.contains("POST /chat/completions") || request.contains("/chat/completions"))
        XCTAssertFalse(request.contains("\"provider\""))
        XCTAssertFalse(request.contains("\"reasoning\""))
        XCTAssertFalse(request.lowercased().contains("authorization:"), "no key, no Authorization header")
    }

    func testTranslationGoesThroughTheSameStream() async throws {
        let server = try FakeHTTPServer { _, _ in
            [.write(FakeHTTPServer.head(200, "OK")), .write(FakeHTTPServer.chunk("Hello.", finish: "stop")), .write("data: [DONE]\n\n")]
        }
        let out = try await client(server).translate(model: "m", info: nil, instructions: TranslatePrompt.defaultInstructions,
                                                     input: "你好。", language: "English") { _ in }
        XCTAssertEqual(out.text, "Hello.")
        let request = server.allRequests[0]
        XCTAssertTrue(request.contains("Translate the text into English."))
        XCTAssertTrue(request.contains("<text>"))
        XCTAssertFalse(request.contains("{language}"))
    }

    func testEndpointParsing() {
        XCTAssertEqual(OpenRouterClient.endpoint(from: " https://openrouter.ai/api/v1/ ")?.absoluteString, "https://openrouter.ai/api/v1")
        XCTAssertEqual(OpenRouterClient.endpoint(from: "https://api.example.com/v1/chat/completions")?.absoluteString, "https://api.example.com/v1")
        XCTAssertEqual(OpenRouterClient.endpoint(from: "http://localhost:11434/v1")?.absoluteString, "http://localhost:11434/v1")
        XCTAssertNil(OpenRouterClient.endpoint(from: "openrouter.ai/api/v1"))
        XCTAssertNil(OpenRouterClient.endpoint(from: "ftp://example.com"))
        XCTAssertNil(OpenRouterClient.endpoint(from: ""))
        XCTAssertTrue(OpenRouterClient.isOpenRouter(URL(string: "https://openrouter.ai/api/v1")!))
        XCTAssertFalse(OpenRouterClient.isOpenRouter(URL(string: "https://api.deepseek.com/v1")!))
    }

    func testDefaultTimeoutIsThreeMinutes() {
        XCTAssertEqual(OpenRouterClient.Tuning().timeout, 180)
    }

    func testRejectedReasoningSettingIsDroppedForFree() async throws {
        let server = try FakeHTTPServer { index, _ in
            if index == 1 {
                return [.write(FakeHTTPServer.head(400, "Bad Request", contentType: "application/json")),
                        .write(#"{"error":{"code":400,"message":"Reasoning is mandatory for this endpoint and cannot be disabled."}}"#)]
            }
            return [.write(FakeHTTPServer.head(200, "OK")), .write(FakeHTTPServer.chunk("OK.", finish: "stop")), .write("data: [DONE]\n\n")]
        }
        let out = try await client(server).polish(model: "m", info: nil, instructions: "", input: "ok", source: .selection) { _ in }
        XCTAssertEqual(out.text, "OK.")
        XCTAssertEqual(out.attempts, 1)
        let requests = server.allRequests
        XCTAssertTrue(requests[0].contains("\"reasoning\":{\"effort\":\"none\"}"))
        XCTAssertFalse(requests[1].contains("\"reasoning\""))
        XCTAssertTrue(requests[1].contains("<text>"))
    }

    func testAuthFailureIsNotRetried() async throws {
        let server = try FakeHTTPServer { _, _ in
            [.write(FakeHTTPServer.head(401, "Unauthorized", contentType: "application/json")), .write(#"{"error":{"code":401,"message":"No auth"}}"#)]
        }
        do {
            _ = try await client(server).polish(model: "m", info: nil, instructions: "", input: "x", source: .dictation) { _ in }
            XCTFail("expected a failure")
        } catch let e as PolishFailure {
            XCTAssertEqual(e.kind, .auth)
        }
        XCTAssertEqual(server.requestCount, 1)
    }

    func testGivesUpAfterFiveAttempts() async throws {
        let server = try FakeHTTPServer { _, _ in
            [.write(FakeHTTPServer.head(502, "Bad Gateway", contentType: "application/json")), .write(#"{"error":{"code":502,"message":"Provider returned error"}}"#)]
        }
        do {
            _ = try await client(server).polish(model: "m", info: nil, instructions: "", input: "x", source: .dictation) { _ in }
            XCTFail("expected a failure")
        } catch let e as PolishFailure {
            XCTAssertEqual(e.kind, .server)
        }
        XCTAssertEqual(server.requestCount, 5)
    }

    func testTheFifthAttemptCanStillSucceed() async throws {
        let server = try FakeHTTPServer { index, _ in
            switch index {
            case 1: return [.write(FakeHTTPServer.head(503, "Service Unavailable", contentType: "application/json")),
                            .write(#"{"error":{"code":503,"message":"No provider available"}}"#)]
            case 2: return [.write(FakeHTTPServer.head(429, "Too Many Requests", contentType: "application/json")),
                            .write(#"{"error":{"code":429,"message":"Rate limited"}}"#)]
            case 3: return [.write(FakeHTTPServer.head(200, "OK")), .write(FakeHTTPServer.chunk("half an ans"))] // cut off
            case 4: return [.write(FakeHTTPServer.head(500, "Internal Server Error", contentType: "application/json")),
                            .write(#"{"error":{"code":500,"message":"Internal error"}}"#)]
            default: return [.write(FakeHTTPServer.head(200, "OK")), .write(FakeHTTPServer.chunk("Done.", finish: "stop")),
                             .write("data: [DONE]\n\n")]
            }
        }
        let out = try await client(server).translate(model: "m", info: nil, instructions: "", input: "完成了。",
                                                     language: "English") { _ in }
        XCTAssertEqual(out.text, "Done.")
        XCTAssertEqual(out.attempts, 5)
        XCTAssertEqual(server.requestCount, 5)
    }

    func testFiveAttemptsByDefault() {
        XCTAssertEqual(OpenRouterClient.Tuning().attempts, 5)
        XCTAssertEqual(OpenRouterClient.maxAttempts, 5)
    }
}

final class DoubaoNetworkTests: XCTestCase {
    func testStreamsAudioAndReturnsTheFinalText() async throws {
        let server = try FakeDoubaoServer()
        let partials = Events()
        let session = DoubaoSession(credentials: DoubaoCredentials(token: "key-123", endpoint: server.url),
                                    urlSession: URLSession(configuration: .ephemeral)) { partials.add(.text($0)) }
        try await session.open(timeout: 5)
        // 0.5 s of silence: two full packets, the rest goes with the last one.
        try await session.send(Data(count: 16_000))
        let result = try await session.finish(timeout: 5)
        XCTAssertEqual(result.text, "你好，世界。")
        XCTAssertEqual(server.receivedAudioBytes, 16_000)
        XCTAssertEqual(server.capturedHeaders["x-api-key"], "key-123")
        XCTAssertEqual(server.capturedHeaders["x-api-resource-id"], DoubaoAPI.defaultResource)
        XCTAssertTrue(partials.all.contains(.text("你好")))
        XCTAssertEqual(session.secondsSent, 0.5, accuracy: 0.001)
    }

    func testClassicCredentialsUseAppIDHeaders() async throws {
        let server = try FakeDoubaoServer()
        let session = DoubaoSession(credentials: DoubaoCredentials(appID: "app-1", token: "tok", endpoint: server.url),
                                    urlSession: URLSession(configuration: .ephemeral))
        try await session.open(timeout: 5)
        session.cancel()
        XCTAssertEqual(server.capturedHeaders["x-api-app-key"], "app-1")
        XCTAssertEqual(server.capturedHeaders["x-api-access-key"], "tok")
        XCTAssertNil(server.capturedHeaders["x-api-key"])
    }

    func testRefusalAtOpenIsExplained() async throws {
        let server = try FakeDoubaoServer()
        server.refuseWith = (45_000_001, "requested resource not granted")
        let session = DoubaoSession(credentials: DoubaoCredentials(token: "k", endpoint: server.url),
                                    urlSession: URLSession(configuration: .ephemeral))
        do {
            try await session.open(timeout: 5)
            XCTFail("expected a refusal")
        } catch let e as SpeechError {
            XCTAssertEqual(e.kind, .quota)
        }
    }

    func testFinalTimeoutKeepsThePartialText() async throws {
        let server = try FakeDoubaoServer()
        server.neverFinish = true
        let session = DoubaoSession(credentials: DoubaoCredentials(token: "k", endpoint: server.url),
                                    urlSession: URLSession(configuration: .ephemeral))
        try await session.open(timeout: 5)
        try await session.send(Data(count: 6_400))
        try await Task.sleep(nanoseconds: 300_000_000)
        do {
            _ = try await session.finish(timeout: 1)
            XCTFail("expected a timeout")
        } catch let e as SpeechError {
            XCTAssertEqual(e.kind, .timeout)
            XCTAssertEqual(e.partialText, "你好")
        }
    }
}
