import XCTest
@testable import ColonPop

final class StartupTests: XCTestCase {
    // Uses the same reconciliation entry point as launch, timer, wake, and menu opening.
    private final class Session {
        var paused = false
        var trusted = true
        var canPost = true
        var canListen = true
        var tapAvailable = true
        var running = false
        var starts = 0

        func refresh() -> AppState {
            AppState.refresh(paused: paused, trusted: trusted, canPost: canPost, canListen: canListen,
                             start: {
                                 self.starts += 1
                                 self.running = self.tapAvailable
                                 return self.running
                             }, stop: { self.running = false })
        }
    }

    func testPostingDeniedStillStartsAndKeepsTheListener() {
        let s = Session()
        s.canPost = false
        XCTAssertEqual(s.refresh(), .nativeInsertion)
        XCTAssertTrue(s.running)
        s.canPost = true
        XCTAssertEqual(s.refresh(), .ready)
        XCTAssertTrue(s.running)
    }

    func testWorkingTapDoesNotRequireAnAdditionalListeningGrant() {
        let s = Session()
        s.canListen = false
        XCTAssertEqual(s.refresh(), .ready)
        XCTAssertTrue(s.running)
    }

    func testRevokingAndRestoringAccessibilityStopsAndRestartsListener() {
        let s = Session()
        XCTAssertEqual(s.refresh(), .ready)
        s.trusted = false
        XCTAssertEqual(s.refresh(), .accessibility)
        XCTAssertFalse(s.running)
        XCTAssertEqual(s.starts, 1)
        s.trusted = true
        XCTAssertEqual(s.refresh(), .ready)
        XCTAssertTrue(s.running)
    }

    func testMissingInputMonitoringAppearsOnlyWhenTapCreationFails() {
        let s = Session()
        s.canListen = false
        s.tapAvailable = false
        XCTAssertEqual(s.refresh(), .inputMonitoring)
        XCTAssertFalse(s.running)
        s.tapAvailable = true
        XCTAssertEqual(s.refresh(), .ready)
        XCTAssertTrue(s.running)
    }

    func testInterruptedTapIsRetriedEvenAfterAReadyState() {
        let s = Session()
        XCTAssertEqual(s.refresh(), .ready)
        s.tapAvailable = false
        XCTAssertEqual(s.refresh(), .unavailable)
        XCTAssertFalse(s.running)
        s.tapAvailable = true
        XCTAssertEqual(s.refresh(), .ready)
        XCTAssertTrue(s.running)
    }

    func testPausePersistsAcrossPermissionChangesUntilResumed() {
        let s = Session()
        s.paused = true
        s.trusted = false
        XCTAssertEqual(s.refresh(), .paused)
        s.trusted = true
        XCTAssertEqual(s.refresh(), .paused)
        XCTAssertEqual(s.starts, 0)
        s.paused = false
        s.canPost = false
        XCTAssertEqual(s.refresh(), .nativeInsertion)
        XCTAssertTrue(s.running)
    }
}
