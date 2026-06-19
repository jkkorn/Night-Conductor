import XCTest

@testable import NightConductor

final class UsageFetchTests: XCTestCase {
    private func should(force: Bool, hasUsage: Bool, fresh: Bool, inBackoff: Bool,
                        age: TimeInterval = 0, threshold: TimeInterval = 180) -> Bool {
        AppState.shouldFetchUsage(force: force, hasUsage: hasUsage, fresh: fresh,
                                  inBackoff: inBackoff, age: age, threshold: threshold)
    }

    // The bug: a 429 backoff stranded a stale reading, so the app held all
    // night on outdated "you're maxed" data even when there was headroom.
    func testStaleReadingBypassesBackoff() {
        // Stale data + active backoff: must retry to recover (forced or due).
        XCTAssertTrue(should(force: true, hasUsage: true, fresh: false, inBackoff: true))
        XCTAssertTrue(should(force: false, hasUsage: true, fresh: false, inBackoff: true, age: 1000))
    }

    func testBackoffStillThrottlesFreshData() {
        // Fresh data + backoff: skip, even when forced (this is the throttle).
        XCTAssertFalse(should(force: true, hasUsage: true, fresh: true, inBackoff: true))
    }

    func testFreshAndNotDueDoesNotRefetch() {
        XCTAssertFalse(should(force: false, hasUsage: true, fresh: true, inBackoff: false, age: 10))
    }

    func testDueByIntervalRefetches() {
        XCTAssertTrue(should(force: false, hasUsage: true, fresh: true, inBackoff: false, age: 300))
    }

    func testFirstLoadAlwaysFetches() {
        XCTAssertTrue(should(force: false, hasUsage: false, fresh: false, inBackoff: false))
    }
}
