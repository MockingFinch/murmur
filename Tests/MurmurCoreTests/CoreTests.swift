import XCTest
@testable import MurmurCore

final class DoubaoCodecTests: XCTestCase {
    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    func testEncodeMatchesTheWireFormat() throws {
        let cases: [(DoubaoFrame, String)] = [
            (DoubaoFrame(kind: .audioOnlyRequest, flags: .sequence, sequence: 2, payload: Data("ab".utf8)),
             "11210000" + "00000002" + "00000002" + "6162"),
            (DoubaoFrame(kind: .audioOnlyRequest, flags: [.sequence, .last], sequence: -3),
             "11230000" + "fffffffd" + "00000000"),
            (DoubaoFrame(kind: .fullClientRequest, flags: .sequence, serialization: .json, sequence: 1, payload: Data("{}".utf8)),
             "11111000" + "00000001" + "00000002" + "7b7d"),
            (DoubaoFrame(kind: .serverError, serialization: .json, errorCode: 45_000_001, payload: Data("x".utf8)),
             "11f01000" + "02aea541" + "00000001" + "78"),
            (DoubaoFrame(kind: .serverAck, flags: .sequence, sequence: 1, payload: Data("ok".utf8)),
             "11b10000" + "00000001" + "6f6b"),
        ]
        for (frame, want) in cases {
            let bytes = try DoubaoCodec.encode(frame)
            XCTAssertEqual(hex(bytes), want)
            XCTAssertEqual(try DoubaoCodec.decode(bytes), frame)
        }
    }

    func testGzipRoundTripAndLastFlag() throws {
        let json = Data(#"{"result":{"text":"你好，world"},"audio_info":{"duration":1200}}"#.utf8)
        let frame = DoubaoFrame(kind: .fullServerResponse, flags: [.sequence, .event], serialization: .json,
                                compression: .gzip, sequence: -5, event: 150, payload: json)
        let back = try DoubaoCodec.decode(try DoubaoCodec.encode(frame))
        XCTAssertEqual(back.payload, json)
        XCTAssertTrue(back.isLast)
        XCTAssertEqual(back.event, 150)
        XCTAssertEqual(DoubaoAPI.parse(back.payload), DoubaoAPI.Result(text: "你好，world", durationMS: 1200))
    }

    func testMalformedFramesAreRejected() {
        let bad: [[UInt8]] = [
            [0x11, 0x90],                                     // short
            [0x21, 0x90, 0x00, 0x00, 0, 0, 0, 1, 0, 0, 0, 0], // version 2
            [0x11, 0x50, 0x00, 0x00, 0, 0, 0, 0],             // unknown type
            [0x11, 0x91, 0x00, 0x00, 0, 0, 0, 1, 0, 0, 0, 9, 0x7b], // payload past the end
            [0x11, 0x91, 0x11, 0x00, 0, 0, 0, 1, 0, 0, 0, 2, 0xde, 0xad], // bad gzip
        ]
        for b in bad { XCTAssertThrowsError(try DoubaoCodec.decode(Data(b))) }
    }

    func testResultParsingVariants() {
        XCTAssertEqual(DoubaoAPI.parse(Data(#"{"result":[{"text":"一"},{"text":"二"}]}"#.utf8))?.text, "一二")
        XCTAssertEqual(DoubaoAPI.parse(Data(#"{"result":{"text":"","utterances":[{"text":"甲"},{"text":"乙"}]}}"#.utf8))?.text, "甲乙")
        XCTAssertNil(DoubaoAPI.parse(Data()))
    }

    func testServerErrorsAreClassified() {
        XCTAssertEqual(SpeechError.fromServer(code: 45_000_002, payload: Data()).kind, .noSpeech)
        XCTAssertTrue(SpeechError.fromServer(code: 55_000_031, payload: Data()).retryable)
        XCTAssertEqual(SpeechError.fromServer(code: 45_000_001, payload: Data(#"{"message":"requested resource not granted"}"#.utf8)).kind, .quota)
        XCTAssertEqual(SpeechError.fromServer(code: 45_000_001, payload: Data(#"{"message":"invalid access key"}"#.utf8)).kind, .auth)
    }

    func testStartRequestAsksForTheSecondPassOnlyOnAsync() throws {
        let on = try JSONSerialization.jsonObject(with: DoubaoAPI.startRequest(secondPass: true)) as! [String: Any]
        let off = try JSONSerialization.jsonObject(with: DoubaoAPI.startRequest(secondPass: false)) as! [String: Any]
        XCTAssertEqual((on["request"] as! [String: Any])["enable_nonstream"] as? Bool, true)
        XCTAssertNil((off["request"] as! [String: Any])["enable_nonstream"])
        XCTAssertEqual((on["audio"] as! [String: Any])["rate"] as? Int, 16_000)
        XCTAssertEqual(DoubaoAPI.endpoint(for: "volc.bigasr.sauc.duration"), DoubaoAPI.duplexEndpoint)
        XCTAssertEqual(DoubaoAPI.endpoint(for: "volc.seedasr.sauc.duration"), DoubaoAPI.asyncEndpoint)
    }
}

final class SSEParserTests: XCTestCase {
    func testStreamWithKeepAlivesThinkingAndDone() throws {
        var p = SSEChunkParser()
        XCTAssertEqual(try p.consume(": OPENROUTER PROCESSING"), .keepAlive)
        XCTAssertEqual(try p.consume(#"data: {"model":"x/y","choices":[{"delta":{"reasoning":"hmm"}}]}"#), .chunk(delta: "", thinking: true))
        XCTAssertEqual(try p.consume(#"data: {"choices":[{"delta":{"content":"你好"}}]}"#), .chunk(delta: "你好", thinking: false))
        XCTAssertEqual(try p.consume(#"data: {"choices":[{"delta":{"content":"。"},"finish_reason":"stop"}]}"#), .chunk(delta: "。", thinking: false))
        XCTAssertEqual(try p.consume("data: [DONE]"), .done)
        XCTAssertNoThrow(try p.finish())
        XCTAssertEqual(p.content, "你好。")
        XCTAssertEqual(p.servedBy, "x/y")
    }

    func testMidStreamErrorIsRetryable() {
        var p = SSEChunkParser()
        XCTAssertThrowsError(try p.consume(#"data: {"error":{"code":502,"message":"Provider returned error"},"choices":[{"delta":{"content":""},"finish_reason":"error"}]}"#)) { e in
            XCTAssertTrue((e as! PolishFailure).retryable)
        }
    }

    func testTruncatedStreamIsAnError() throws {
        var p = SSEChunkParser()
        _ = try p.consume(#"data: {"choices":[{"delta":{"content":"half"}}]}"#)
        XCTAssertThrowsError(try p.finish()) { e in XCTAssertEqual((e as! PolishFailure).kind, .truncated) }
    }
}

final class PromptTests: XCTestCase {
    func testCleanStripsWrappers() {
        XCTAssertEqual(PolishPrompt.clean("<think>plan</think>\n你好。", input: "你好"), "你好。")
        XCTAssertEqual(PolishPrompt.clean("“明天见。”", input: "明天见"), "明天见。")
        XCTAssertEqual(PolishPrompt.clean("<transcript>\nHi there.\n</transcript>", input: "hi there"), "Hi there.")
        XCTAssertEqual(PolishPrompt.clean("```text\nok\n```", input: "ok"), "ok")
        // Quotes the speaker really said stay.
        XCTAssertEqual(PolishPrompt.clean("\"quoted\"", input: "\"quoted\""), "\"quoted\"")
    }

    func testMessagesFrameTheInput() {
        let d = PolishPrompt.messages(instructions: "Rules.", input: "嗯 你好", source: .dictation)
        XCTAssertTrue(d.system.hasPrefix("Rules."))
        XCTAssertEqual(d.user, "<transcript>\n嗯 你好\n</transcript>")
        let s = PolishPrompt.messages(instructions: "Rules.", input: "text", source: .selection)
        XCTAssertEqual(s.user, "<text>\ntext\n</text>")
    }

    func testTranslationNamesTheLanguage() {
        let m = TranslatePrompt.messages(instructions: TranslatePrompt.defaultInstructions, input: "你好", language: " Japanese ")
        XCTAssertTrue(m.system.hasPrefix("You are a professional translator. Translate the text into Japanese."))
        XCTAssertFalse(m.system.contains(TranslatePrompt.placeholder))
        XCTAssertTrue(m.system.contains("text to translate into Japanese"))
        XCTAssertEqual(m.user, "<text>\n你好\n</text>")
        // Instructions without the placeholder still get the language from the frame;
        // a blank language falls back to English.
        let plain = TranslatePrompt.messages(instructions: "Be brief.", input: "x", language: "  ")
        XCTAssertTrue(plain.system.hasPrefix("Be brief."))
        XCTAssertTrue(plain.system.contains("Reply with the English translation only"))
        let bare = TranslatePrompt.messages(instructions: "", input: "x", language: "French")
        XCTAssertTrue(bare.system.hasPrefix("The user message holds text to translate into French"))
    }

    func testDefaultPromptIsTheUsers() {
        XCTAssertTrue(PolishPrompt.defaultInstructions.hasPrefix("You are a transcription enhancement assistant."))
        XCTAssertTrue(PolishPrompt.defaultInstructions.hasSuffix("surrounding quotation marks."))
    }

    func testMetrics() {
        XCTAssertEqual(TextMetrics.visibleCharacters("a b\n你好"), 4)
        XCTAssertEqual(TextMetrics.cjkCharacters("API 很快"), 2)
    }
}

final class ReasoningTests: XCTestCase {
    func testLeastReasoning() {
        XCTAssertEqual(ReasoningSetting.least(for: nil), .effort("none"))
        XCTAssertEqual(ReasoningSetting.least(for: OpenRouterModel(id: "a/b", name: "")), .omit)
        XCTAssertEqual(ReasoningSetting.least(for: OpenRouterModel(id: "a/b", name: "", supportsReasoning: true, efforts: ["high", "low", "none"])), .effort("none"))
        XCTAssertEqual(ReasoningSetting.least(for: OpenRouterModel(id: "a/b", name: "", supportsReasoning: true, reasoningMandatory: true, efforts: ["high", "medium", "low"])), .effort("low"))
        XCTAssertEqual(ReasoningSetting.least(for: OpenRouterModel(id: "a/b", name: "", supportsReasoning: true, reasoningMandatory: true, efforts: ["high", "minimal"])), .effort("minimal"))
        XCTAssertEqual(ReasoningSetting.least(for: OpenRouterModel(id: "a/b", name: "", supportsReasoning: true, efforts: ["high", "low"])), .disabled)
    }

    func testModelListParsing() throws {
        let json = #"""
        {"data":[
          {"id":"g/flash","name":"G Flash","created":10,"context_length":1000,
           "architecture":{"output_modalities":["text"]},"endpoints":["/api/v1/chat/completions"],
           "pricing":{"prompt":"0.0000001","completion":"0.0000004"},
           "supported_parameters":["reasoning"],"reasoning":{"mandatory":true,"supported_efforts":["high","low"]}},
          {"id":"g/flash:batch","name":"batch","architecture":{"output_modalities":["text"]}},
          {"id":"g/image","name":"Image","architecture":{"output_modalities":["image"]}}
        ]}
        """#
        let models = try OpenRouterModel.parseList(Data(json.utf8))
        XCTAssertEqual(models.map(\.id), ["g/flash"])
        XCTAssertEqual(models[0].inputPrice, 0.1, accuracy: 1e-9)
        XCTAssertTrue(models[0].reasoningMandatory)
    }

    func testHTTPFailures() {
        XCTAssertEqual(PolishFailure.http(status: 400, body: Data(#"{"error":{"message":"Reasoning is mandatory for this endpoint"}}"#.utf8), retryAfter: nil).kind, .reasoningRejected)
        XCTAssertFalse(PolishFailure.http(status: 401, body: Data(), retryAfter: nil).retryable)
        XCTAssertTrue(PolishFailure.http(status: 429, body: Data(), retryAfter: 2).retryable)
        XCTAssertTrue(PolishFailure.http(status: 502, body: Data(), retryAfter: nil).retryable)
    }
}

final class StatsTests: XCTestCase {
    func testSummary() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let yesterday = now.addingTimeInterval(-86_400)
        let records = [
            UsageRecord(date: now, kind: .dictation, audioSeconds: 30, text: "你好世界，今天天气不错。", polish: .polished, waitSeconds: 1, attempts: 1),
            UsageRecord(date: now, kind: .refine, audioSeconds: 0, text: "Hello there", polish: .fallback, waitSeconds: 2, attempts: 3),
            UsageRecord(date: yesterday, kind: .dictation, audioSeconds: 10, text: "abc", polish: .skipped, waitSeconds: 0.5, attempts: 0),
        ]
        let s = UsageMath.summarize(records, now: now, days: 7, calendar: cal)
        XCTAssertEqual(s.today.dictations, 1)
        XCTAssertEqual(s.today.refines, 1)
        XCTAssertEqual(s.allTime.uses, 3)
        XCTAssertEqual(s.today.characters, 12 + 10)
        XCTAssertEqual(s.days.count, 7)
        XCTAssertEqual(s.days.last?.uses, 2)
        XCTAssertEqual(s.polishRate, 0.5)
        XCTAssertEqual(s.medianWait, 1)
        XCTAssertEqual(s.streak, 2)
    }

    func testShortcutDisplay() {
        XCTAssertEqual(Shortcut.default.display, "⌃X")
        XCTAssertEqual(Shortcut(keyCode: 0x31, modifiers: Shortcut.option | Shortcut.command).caps, ["⌥", "⌘", "Space"])
        XCTAssertFalse(Shortcut(keyCode: 0x07, modifiers: Shortcut.shift).isValid)
        XCTAssertTrue(Shortcut(keyCode: 0x60, modifiers: 0).isValid)
    }
}
