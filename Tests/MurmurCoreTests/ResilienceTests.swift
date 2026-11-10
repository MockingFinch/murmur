import XCTest
@testable import MurmurCore

/// A dictation must survive the connection to Doubao failing at any moment.
final class ResilienceTests: XCTestCase {
    /// `seconds` of audio; every sample of second k holds k, which the fake
    /// server hears as the sentence "第k句。".
    private func speech(seconds: Int) -> Data {
        var samples: [Int16] = []
        for k in 1 ... seconds { samples += Array(repeating: Int16(k), count: 16_000) }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func sentences(_ range: ClosedRange<Int>) -> String { range.map { "第\($0)句。" }.joined() }

    private func tuning() -> ResilientTranscriber.Tuning {
        var t = ResilientTranscriber.Tuning()
        t.openTimeout = 2
        t.backoff = [0.05]
        t.catchUpPause = 0.01
        return t
    }

    private func transcriber(_ server: FakeDoubaoServer, _ tape: PCMTape,
                             statuses: Collector<ResilientTranscriber.Status>? = nil) -> ResilientTranscriber {
        ResilientTranscriber(credentials: DoubaoCredentials(token: "k", endpoint: server.url), tape: tape, tuning: tuning(),
                             onStatus: { statuses?.add($0) })
    }

    func testADropKeepsConfirmedSentencesAndResendsOnlyTheRest() async throws {
        let server = try FakeDoubaoServer()
        server.sentences = true
        server.dropAfterBytes = [1: 112_000] // 3.5 s into the first connection
        let statuses = Collector<ResilientTranscriber.Status>()
        let out = try await transcriber(server, PCMTape(speech(seconds: 6)), statuses: statuses).finish()

        XCTAssertEqual(out.text, sentences(1 ... 6), "every sentence once, in order")
        XCTAssertTrue(out.isComplete)
        XCTAssertEqual(out.reconnects, 1)
        XCTAssertEqual(server.connectionCount, 2)
        // The three confirmed seconds were not sent again: less than one second was.
        XCTAssertGreaterThan(server.receivedAudioBytes, 6 * 32_000)
        XCTAssertLessThan(server.receivedAudioBytes, 7 * 32_000)
        XCTAssertTrue(statuses.all.contains { if case .reconnecting = $0 { return true }; return false })
        XCTAssertEqual(statuses.all.last, .live)
    }

    func testKeepsTryingWhileTheUserIsStillSpeaking() async throws {
        let server = try FakeDoubaoServer()
        server.sentences = true
        server.refuse = { $0 <= 3 } // offline for the first three tries
        let tape = PCMTape()
        let t = transcriber(server, tape)
        t.start()
        let audio = speech(seconds: 4)
        var offset = 0
        while offset < audio.count { // spoken at ten times real time
            let end = min(audio.count, offset + 6_400)
            tape.append(audio.subdata(in: offset ..< end))
            offset = end
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let out = try await t.finish()

        XCTAssertEqual(out.text, sentences(1 ... 4))
        XCTAssertTrue(out.isComplete)
        XCTAssertEqual(server.connectionCount, 4)
    }

    func testWhenDoubaoNeverComesBackWhatItConfirmedIsKept() async throws {
        let server = try FakeDoubaoServer()
        server.sentences = true
        server.dropAfterBytes = [1: 112_000]
        server.refuse = { $0 >= 2 } // gone for good after the drop
        let out = try await transcriber(server, PCMTape(speech(seconds: 6))).finish()

        XCTAssertEqual(out.text, sentences(1 ... 3) + "第4", "confirmed sentences, then the words in progress")
        XCTAssertFalse(out.isComplete)
        XCTAssertEqual(out.unconfirmedSeconds, 3, accuracy: 0.01)
        XCTAssertEqual(server.connectionCount, 1 + ResilientTranscriber.Tuning().attemptsAfterStop)
    }

    func testARefusedKeyIsNotRetried() async throws {
        let server = try FakeDoubaoServer()
        server.refuseWith = (45_000_001, "requested resource not granted")
        do {
            _ = try await transcriber(server, PCMTape(speech(seconds: 2))).finish()
            XCTFail("expected the refusal")
        } catch let e as SpeechError {
            XCTAssertFalse(e.retryable)
        }
        XCTAssertEqual(server.connectionCount, 1)
    }

    func testARefusalMidwayKeepsWhatCameBeforeAndSaysWhy() async throws {
        let server = try FakeDoubaoServer()
        server.sentences = true
        server.dropAfterBytes = [1: 112_000]
        // From the second connection on, refused for good: a quota, not the network.
        server.refuseFrom = (2, 45_000_001, "quota exceeded")
        let statuses = Collector<ResilientTranscriber.Status>()
        let out = try await transcriber(server, PCMTape(speech(seconds: 6)), statuses: statuses).finish()

        XCTAssertEqual(out.text, sentences(1 ... 3) + "第4")
        XCTAssertFalse(out.isComplete)
        XCTAssertNotNil(out.problem)
        XCTAssertEqual(server.connectionCount, 2, "a refusal isn't retried")
        XCTAssertTrue(statuses.all.contains { if case .unavailable = $0 { return true }; return false })
    }

    func testSentencesAreParsedAndConfirmedInOrder() {
        let json = #"""
        {"audio_info":{"duration":3000},"result":{"text":"一。二。三","utterances":[
          {"text":"一。","start_time":0,"end_time":900,"definite":true},
          {"text":"二。","start_time":1000,"end_time":1900,"definite":true},
          {"text":"三","start_time":2000,"end_time":2600,"definite":false}]}}
        """#
        let r = DoubaoAPI.parse(Data(json.utf8))!
        XCTAssertEqual(r.utterances.count, 3)
        XCTAssertEqual(r.confirmed.text, "一。二。")
        XCTAssertEqual(r.confirmed.endMS, 1900)
        XCTAssertEqual(r.unconfirmedText, "三")
        XCTAssertEqual(PCMTape.offset(ms: 1900), 60_800)
    }

    func testTranscriptPiecesJoinLikeTheLanguage() {
        XCTAssertEqual(Transcript.join(["你好。", "世界"]), "你好。世界")
        XCTAssertEqual(Transcript.join(["Ship it on Wednesday.", "Then collect feedback."]),
                       "Ship it on Wednesday. Then collect feedback.")
        XCTAssertEqual(Transcript.join(["", " half ", "", "done"]), "half done")
        XCTAssertEqual(Transcript.join(["这个 API", "很快。"]), "这个 API很快。")
    }
}

final class Collector<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}
