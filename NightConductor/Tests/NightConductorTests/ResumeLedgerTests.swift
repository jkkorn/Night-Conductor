import XCTest

@testable import NightConductor

/// Budget-ledger tests for the C1 fix (success vs failure tracking).
/// Day-key / immutability tests live in PolicyTests.
final class ResumeLedgerBudgetTests: XCTestCase {
    func testSuccessSpendsBudgetFailureDoesNot() {
        var night = ResumeLedger(key: "2026-06-16")
        night = night.recordingFailure("s1")
        night = night.recordingFailure("s1")
        // A pile of failures must NOT consume the per-night budget.
        XCTAssertEqual(night.total, 0)
        XCTAssertEqual(night.count(for: "s1"), 0)
        XCTAssertEqual(night.failureCount(for: "s1"), 2)

        night = night.recordingSuccess("s1")
        XCTAssertEqual(night.total, 1)            // only the success counts
        XCTAssertEqual(night.count(for: "s1"), 1)
        XCTAssertEqual(night.failureCount(for: "s1"), 2) // failures unchanged
    }

    func testSuccessAndFailureAreIndependentPerSession() {
        var night = ResumeLedger(key: "k")
        night = night.recordingSuccess("a").recordingSuccess("b").recordingFailure("c")
        XCTAssertEqual(night.total, 2)
        XCTAssertEqual(night.count(for: "a"), 1)
        XCTAssertEqual(night.count(for: "c"), 0)
        XCTAssertEqual(night.failureCount(for: "c"), 1)
    }

    func testRecordingReturnsNewValueWithoutMutating() {
        let base = ResumeLedger(key: "k")
        let next = base.recordingSuccess("x")
        XCTAssertEqual(base.total, 0)   // immutable: original untouched
        XCTAssertEqual(next.total, 1)
    }

    func testPersistsSuccessAndFailureSeparately() {
        let defaults = makeDefaults()
        var night = ResumeLedger.load(defaults: defaults)
        night = night.recordingSuccess("s1").recordingFailure("s2")
        night.save(defaults: defaults)

        let reloaded = ResumeLedger(
            key: night.key,
            counts: defaults.dictionary(forKey: "ledgerCounts") as? [String: Int] ?? [:],
            failures: defaults.dictionary(forKey: "ledgerFailures") as? [String: Int] ?? [:]
        )
        XCTAssertEqual(reloaded.count(for: "s1"), 1)
        XCTAssertEqual(reloaded.failureCount(for: "s2"), 1)
    }

    func testNewDayResetsTheDailyTotalButNotPerStallTries() {
        let defaults = makeDefaults()
        defaults.set("1999-01-01", forKey: "ledgerDay")
        defaults.set(7, forKey: "ledgerDayTotal")
        defaults.set(["old": 5], forKey: "ledgerCounts")
        defaults.set(["old": 9], forKey: "ledgerFailures")
        // A new day: a fresh daily budget, but a stall that already failed
        // its tries stays failed (it would otherwise be hammered daily).
        let ledger = ResumeLedger.load(defaults: defaults)
        XCTAssertNotEqual(ledger.key, "1999-01-01")
        XCTAssertEqual(ledger.total, 0)
        XCTAssertEqual(ledger.failureCount(for: "old"), 9)
    }

    // C2: the same Claude session under two source IDs shares ONE per-session
    // counter, so it can't quietly get 2× the per-session retry budget by
    // being resumed once as a Conductor session and once as a terminal one.
    func testLedgerKeyCollapsesCrossSourceDuplicates() {
        let claude = "824cbb1e-3ace-4666-8674-d7bd19f442a6"
        let conductor = StalledSession(
            sessionID: claude, claudeSessionID: claude, title: "t",
            workspacePath: "/w", errorText: "limit", stalledAt: nil, source: .conductor)
        let terminal = StalledSession(
            sessionID: "cc-\(claude)", claudeSessionID: claude, title: "t",
            workspacePath: "/w", errorText: "limit", stalledAt: nil, source: .claudeCode)
        XCTAssertEqual(conductor.ledgerKey, terminal.ledgerKey) // same counter

        var night = ResumeLedger(key: "k")
        night = night.recordingSuccess(conductor.ledgerKey)
        night = night.recordingSuccess(terminal.ledgerKey)
        // Both resumes accumulate under one key — the per-session cap (3)
        // is now shared across sources instead of being 3-per-source.
        XCTAssertEqual(night.count(for: conductor.ledgerKey), 2)
        XCTAssertEqual(night.count(for: terminal.ledgerKey), 2)
    }

    func testLedgerKeyFallsBackToSessionIDWhenClaudeIDEmpty() {
        let s = StalledSession(
            sessionID: "only-id", claudeSessionID: "", title: "t",
            workspacePath: "/w", errorText: "limit", stalledAt: nil)
        XCTAssertEqual(s.ledgerKey, "only-id")
    }

    func testResumeSummaryAccumulatesThenClearsOnce() {
        let d = makeDefaults()
        XCTAssertNil(ResumeSummary.takeIfAny(defaults: d))
        ResumeSummary.recordUnattended(key: "a", title: "A", inApp: true, defaults: d)
        ResumeSummary.recordUnattended(key: "b", title: "B", inApp: false, defaults: d)
        XCTAssertEqual(ResumeSummary.takeIfAny(defaults: d),
                       ResumeSummary.Pending(count: 2, title: "B", background: 1))
        XCTAssertNil(ResumeSummary.takeIfAny(defaults: d)) // posted once, not twice
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "ResumeLedgerTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }
}
