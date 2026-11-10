import Foundation
import MurmurCore
import XCTest

final class SilenceWatchTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testNothingSaidEndsAfterTheLimit() {
        let watch = SilenceWatch(limit: 120, start: t0)
        XCTAssertFalse(watch.expired(at: at(119)))
        XCTAssertTrue(watch.expired(at: at(120)))
    }

    func testNewWordsStartTheQuietOver() {
        var watch = SilenceWatch(limit: 120, start: t0)
        watch.heard("So for next week", at: at(100))
        XCTAssertFalse(watch.expired(at: at(200)))
        watch.heard("So for next week, I think", at: at(210))
        XCTAssertFalse(watch.expired(at: at(329)))
        XCTAssertTrue(watch.expired(at: at(330)))
    }

    func testTheSameTextAgainIsNotNew() {
        var watch = SilenceWatch(limit: 120, start: t0)
        watch.heard("Hello", at: at(10))
        watch.heard("Hello", at: at(60))
        watch.heard("Hello", at: at(120))
        XCTAssertTrue(watch.expired(at: at(130)))
    }

    func testTimeWithoutAConnectionDoesNotCount() {
        var watch = SilenceWatch(limit: 120, start: t0)
        watch.connected(false, at: at(90))   // 90 s of quiet so far
        XCTAssertEqual(watch.quiet(at: at(600)), 90, accuracy: 0.001)
        XCTAssertFalse(watch.expired(at: at(600)))
        watch.connected(true, at: at(600))
        XCTAssertFalse(watch.expired(at: at(629)))
        XCTAssertTrue(watch.expired(at: at(630)))
    }

    func testWordsCaughtUpAfterAReconnectCount() {
        var watch = SilenceWatch(limit: 120, start: t0)
        watch.connected(false, at: at(100))
        watch.heard("Words spoken while it was down", at: at(300))  // arriving as it catches up
        watch.connected(true, at: at(300))
        XCTAssertEqual(watch.quiet(at: at(360)), 60, accuracy: 0.001)
        XCTAssertFalse(watch.expired(at: at(419)))
        XCTAssertTrue(watch.expired(at: at(420)))
    }

    func testRepeatedStatusChangesDoNotRestartTheClock() {
        var watch = SilenceWatch(limit: 120, start: t0)
        watch.connected(true, at: at(50))   // already connected: nothing changes
        XCTAssertTrue(watch.expired(at: at(120)))
        watch.connected(false, at: at(130))
        watch.connected(false, at: at(200))
        XCTAssertEqual(watch.quiet(at: at(300)), 130, accuracy: 0.001)
    }
}
