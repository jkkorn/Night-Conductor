import XCTest

@testable import NightConductor

/// The Activity panel reads `ResumeHistory.recent()` — the durable, persisted
/// record of what was resumed. These pin its ordering and cap so the panel is
/// never falsely empty after a relaunch (the bug it replaced) and never blows
/// up the popover with an unbounded list.
final class ResumeHistoryTests: XCTestCase {
    private func event(_ title: String, _ secondsAgo: TimeInterval,
                       from base: Date, inConductor: Bool = false) -> ResumeEvent {
        ResumeEvent(date: base.addingTimeInterval(-secondsAgo), title: title,
                    kind: "usage_limit", inConductor: inConductor)
    }

    func testRecentIsNewestFirst() {
        let d = makeDefaults()
        let base = Date()
        ResumeHistory.record(event("older", 300, from: base), defaults: d)
        ResumeHistory.record(event("newest", 0, from: base, inConductor: true), defaults: d)
        ResumeHistory.record(event("middle", 150, from: base), defaults: d)

        XCTAssertEqual(ResumeHistory.recent(defaults: d).map(\.title),
                       ["newest", "middle", "older"])
    }

    func testRecentRespectsLimit() {
        let d = makeDefaults()
        let base = Date()
        for i in 0..<5 { ResumeHistory.record(event("t\(i)", Double(i), from: base), defaults: d) }

        XCTAssertEqual(ResumeHistory.recent(limit: 2, defaults: d).count, 2)
        XCTAssertEqual(ResumeHistory.recent(limit: 0, defaults: d).count, 0)   // negative-safe
        XCTAssertEqual(ResumeHistory.recent(limit: -3, defaults: d).count, 0)
        XCTAssertEqual(ResumeHistory.recent(limit: 100, defaults: d).count, 5) // cap above count
    }

    func testRecentIsEmptyWithNoHistory() {
        XCTAssertTrue(ResumeHistory.recent(defaults: makeDefaults()).isEmpty)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "ResumeHistoryTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }
}
