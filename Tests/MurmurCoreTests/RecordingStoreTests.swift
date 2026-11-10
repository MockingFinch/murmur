import XCTest
@testable import MurmurCore

/// Recordings stay on disk until their words are in.
final class RecordingStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-recordings-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func audio(seconds: Double, value: Int16 = 7) -> Data {
        let samples = Array(repeating: value, count: Int(seconds * 16_000))
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func testARecordingIsWrittenWhileItGrows() throws {
        let store = RecordingStore(directory: dir)
        let tape = PCMTape()
        let writer = try XCTUnwrap(store.begin(translate: true))
        writer.follow(tape, every: 0.02)
        tape.append(audio(seconds: 1))
        // Written a moment behind the microphone, without waiting for the end.
        let deadline = Date().addingTimeInterval(2)
        while writer.bytesWritten < 32_000, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(writer.bytesWritten, 32_000)
        XCTAssertEqual(store.all().first?.seconds ?? 0, 1, accuracy: 0.001)

        tape.append(audio(seconds: 0.5, value: 9))
        writer.close()
        let saved = try XCTUnwrap(store.all().first)
        XCTAssertEqual(saved.seconds, 1.5, accuracy: 0.001)
        XCTAssertTrue(saved.translate)
        XCTAssertEqual(store.audio(saved.id), tape.all, "byte for byte")
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("\(saved.id).pcm").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600, "readable only by the user")
    }

    func testDeletedOnceDoneAndPrunedAfterAWeek() throws {
        let store = RecordingStore(directory: dir)
        for (age, seconds) in [(0.0, 2.0), (8 * 86_400.0, 2.0), (0.0, 0.1)] {
            let tape = PCMTape(audio(seconds: seconds))
            let writer = try XCTUnwrap(store.begin(translate: false, date: Date().addingTimeInterval(-age)))
            writer.follow(tape)
            writer.close()
        }
        XCTAssertEqual(store.all().count, 3)
        store.prune()
        let left = store.all()
        XCTAssertEqual(left.count, 1, "the week-old one and the one too short for a word are gone")
        XCTAssertEqual(left.first?.seconds ?? 0, 2, accuracy: 0.001)
        store.delete(left[0].id)
        XCTAssertTrue(store.all().isEmpty)
    }

    func testANewestFirstList() throws {
        let store = RecordingStore(directory: dir)
        for age in [300.0, 0, 60] {
            let w = try XCTUnwrap(store.begin(translate: false, date: Date().addingTimeInterval(-age)))
            w.follow(PCMTape(audio(seconds: 1)))
            w.close()
        }
        let dates = store.all().map(\.date)
        XCTAssertEqual(dates, dates.sorted(by: >))
    }
}
