import XCTest
@testable import NightConductor

final class ResetWatchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    // MARK: keep awake only around a reset that work is waiting for

    func testNoWaitingWorkNeverHoldsTheMacAwake() {
        XCTAssertFalse(ResetWatch.shouldKeepAwake(
            armed: true, waiting: 0, budgetAllows: true, nextReset: now.addingTimeInterval(60), now: now))
    }

    func testDisarmedNeverHoldsTheMacAwake() {
        XCTAssertFalse(ResetWatch.shouldKeepAwake(
            armed: false, waiting: 3, budgetAllows: true, nextReset: nil, now: now))
    }

    func testHoldsWhileResumingIsPossible() {
        XCTAssertTrue(ResetWatch.shouldKeepAwake(
            armed: true, waiting: 2, budgetAllows: true, nextReset: now.addingTimeInterval(5 * 86_400), now: now))
    }

    func testHoldsInTheLeadUpToTheReset() {
        let soon = now.addingTimeInterval(ResetWatch.awakeLead - 60)
        XCTAssertTrue(ResetWatch.shouldKeepAwake(
            armed: true, waiting: 1, budgetAllows: false, nextReset: soon, now: now))
    }

    func testLetsTheMacSleepWhenTheResetIsFarAway() {
        let later = now.addingTimeInterval(ResetWatch.awakeLead + 3600)
        XCTAssertFalse(ResetWatch.shouldKeepAwake(
            armed: true, waiting: 4, budgetAllows: false, nextReset: later, now: now))
    }

    func testUnknownResetDoesNotHoldAwakeForever() {
        XCTAssertFalse(ResetWatch.shouldKeepAwake(
            armed: true, waiting: 4, budgetAllows: false, nextReset: nil, now: now))
    }

    // MARK: noticing that a week reset

    func testResetDetectedWhenTheOldResetPassedAndANewOneIsLater() {
        let old = now.addingTimeInterval(-600)
        let new = old.addingTimeInterval(7 * 86_400)
        XCTAssertTrue(ResetWatch.didReset(previous: old, current: new, now: now))
    }

    func testSameWindowIsNotAReset() {
        let r = now.addingTimeInterval(3600)
        XCTAssertFalse(ResetWatch.didReset(previous: r, current: r.addingTimeInterval(30), now: now))
    }

    func testFirstReadingIsNotAReset() {
        XCTAssertFalse(ResetWatch.didReset(previous: nil, current: now.addingTimeInterval(3600), now: now))
    }

    func testAnEarlyNewWindowIsAResetEvenBeforeTheOldTime() {
        // A free reset restarts the week early: the reset jumps a week out
        // while the old reset time is still in the future.
        let old = now.addingTimeInterval(2 * 86_400)
        let new = now.addingTimeInterval(7 * 86_400)
        XCTAssertTrue(ResetWatch.didReset(previous: old, current: new, now: now))
    }

    // MARK: wake schedule for the reset

    func testWakeSpecIsAFewMinutesBeforeTheResetOnItsWeekday() {
        // 2027-01-15 is a Friday. Reset at 02:00 UTC -> wake Friday 01:55.
        let reset = utc.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 2, minute: 0))!
        let spec = ResetWatch.wakeSpec(for: reset, calendar: utc)
        XCTAssertEqual(spec, ResetWatch.WakeSpec(day: "F", time: "01:55:00"))
    }

    func testWakeSpecCrossesMidnightBackToThePreviousDay() {
        // Saturday 00:02 rounds to 00:00 -> wake Friday 23:55.
        let reset = utc.date(from: DateComponents(year: 2027, month: 1, day: 16, hour: 0, minute: 2))!
        XCTAssertEqual(ResetWatch.wakeSpec(for: reset, calendar: utc),
                       ResetWatch.WakeSpec(day: "F", time: "23:55:00"))
    }

    // Review #5: the API's reset jitters across the minute boundary; the
    // spec must not flip (or settings would claim the reset moved).
    func testWakeSpecIgnoresSubSecondJitter() {
        let two = utc.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 2, minute: 0))!
        XCTAssertEqual(ResetWatch.wakeSpec(for: two.addingTimeInterval(-0.3), calendar: utc),
                       ResetWatch.wakeSpec(for: two.addingTimeInterval(0.1), calendar: utc))
    }

    // Review #2: a reset in the past means stale data; hold only briefly.
    func testPastResetHoldsOnlyForTheGrace() {
        XCTAssertTrue(ResetWatch.shouldKeepAwake(
            armed: true, waiting: 1, budgetAllows: false, nextReset: now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(ResetWatch.shouldKeepAwake(
            armed: true, waiting: 1, budgetAllows: false,
            nextReset: now.addingTimeInterval(-ResetWatch.awakeGrace - 60), now: now))
        XCTAssertFalse(ResetWatch.shouldKeepAwake(
            armed: true, waiting: 1, budgetAllows: false, nextReset: now.addingTimeInterval(-3 * 86_400), now: now))
    }

    // Review #7: an older date from a fallback source must not rewind the
    // remembered reset (that would fake a second "week reset" later).
    func testRememberedResetOnlyMovesForward() {
        let stored = now.addingTimeInterval(6 * 86_400)
        XCTAssertFalse(ResetWatch.shouldStore(current: now.addingTimeInterval(2 * 86_400), previous: stored, now: now))
        XCTAssertTrue(ResetWatch.shouldStore(current: stored.addingTimeInterval(7 * 86_400), previous: stored, now: now))
        XCTAssertTrue(ResetWatch.shouldStore(current: now.addingTimeInterval(86_400),
                                             previous: now.addingTimeInterval(-60), now: now)) // old one passed
        XCTAssertTrue(ResetWatch.shouldStore(current: now, previous: nil, now: now))
    }

    // Review #6: read the existing repeating schedule before replacing it.
    func testParsesRepeatingPowerEvents() {
        let out = """
        Repeating power events:
          wakepoweron at 8:00AM weekdays only
          sleep at 11:00PM every day
        Scheduled power events:
         [0]  wake at 11/27/2026 01:55:00 by 'pmset'
        """
        XCTAssertEqual(PowerManager.parseRepeating(out),
                       ["wakepoweron at 8:00AM weekdays only", "sleep at 11:00PM every day"])
        XCTAssertEqual(PowerManager.parseRepeating(""), [])
    }

    func testSundayUsesPmsetsLetter() {
        let reset = utc.date(from: DateComponents(year: 2027, month: 1, day: 17, hour: 9, minute: 30))!
        XCTAssertEqual(ResetWatch.wakeSpec(for: reset, calendar: utc)?.day, "U")
    }

    // MARK: words

    func testCountdownWords() {
        XCTAssertEqual(ResetWatch.countdown(to: now.addingTimeInterval(40 * 60), now: now), "in 40m")
        XCTAssertEqual(ResetWatch.countdown(to: now.addingTimeInterval(14 * 3600 + 600), now: now), "in 14h")
        XCTAssertEqual(ResetWatch.countdown(to: now.addingTimeInterval(2 * 86_400 + 3 * 3600), now: now), "in 2d 3h")
        XCTAssertEqual(ResetWatch.countdown(to: now.addingTimeInterval(-5), now: now), "now")
    }

    func testFreeResetHonestyPerProvider() {
        XCTAssertEqual(ResetWatch.freeResetNote(provider: .chatgpt, available: 1), "1 free reset available. Use it in Codex when you want.")
        XCTAssertEqual(ResetWatch.freeResetNote(provider: .chatgpt, available: 0), "No free resets right now.")
        XCTAssertTrue(ResetWatch.freeResetNote(provider: .claude, available: 0).contains("doesn't share"))
        XCTAssertTrue(ResetWatch.freeResetNote(provider: .grok, available: 0).contains("doesn't report"))
    }
}

final class StallWindowTests: XCTestCase {
    // Review #1: a weekly reset can be up to 7 days after the stall.
    func testAStallOutlivesAWholeWeek() {
        XCTAssertGreaterThan(StalledSession.maxAge, 7 * 86_400)
    }

    // Review #4: caps key on the stall, so the same stall isn't retried every
    // day, while a new stall of the same session gets fresh tries.
    func testStallKeyDistinguishesStallsOfOneSession() {
        let a = StalledSession(sessionID: "s", claudeSessionID: "c", title: "t", workspacePath: "/w",
                               errorText: "limit", stalledAt: Date(timeIntervalSince1970: 100))
        let b = StalledSession(sessionID: "s", claudeSessionID: "c", title: "t", workspacePath: "/w",
                               errorText: "limit", stalledAt: Date(timeIntervalSince1970: 900_000))
        XCTAssertNotEqual(a.stallKey, b.stallKey)
        XCTAssertEqual(a.ledgerKey, b.ledgerKey)
    }

    func testPerStallCountsSurviveMidnightButTheDailyTotalResets() {
        let suite = "StallWindowTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let day1 = Date(timeIntervalSince1970: 1_800_000_000)
        let day2 = day1.addingTimeInterval(86_400)
        ResumeLedger.load(now: day1, defaults: d)
            .recordingSuccess("k", at: day1).recordingSuccess("k", at: day1).recordingSuccess("k", at: day1)
            .save(defaults: d)
        let next = ResumeLedger.load(now: day2, defaults: d)
        XCTAssertEqual(next.total, 0)            // fresh daily budget
        XCTAssertEqual(next.count(for: "k"), 3)  // but this stall had its three tries
        XCTAssertEqual(next.lastResumed["k"], day1) // and the cool-down survives a relaunch
    }

    // Review #3: three resumes of one session is one session.
    func testSummaryCountsSessionsNotAttempts() {
        let suite = "Summary-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        for _ in 0..<3 { ResumeSummary.recordUnattended(key: "same", title: "T", inApp: false, defaults: d) }
        XCTAssertEqual(ResumeSummary.takeIfAny(defaults: d), ResumeSummary.Pending(count: 1, title: "T", background: 1))
    }
}

final class AtLimitStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func claude(_ pct: Double, readAgo: TimeInterval = 60) -> ProviderUsage {
        ProviderUsage(provider: .claude, source: "Claude Code", plan: nil,
                      weekly: UsageWindow(utilization: pct, resetsAt: now.addingTimeInterval(36 * 3600)),
                      readAt: now.addingTimeInterval(-readAgo))
    }

    // At 100% the week is spent: "ease off" or "you'll run out" would be false.
    func testFullWeekIsAtTheLimitNotAhead() {
        let a = BurnAssessment(evenPacePercent: 60, runsOutAt: nil, recentRate: 9, usualRate: 3, isBurningHot: true)
        let status = PaceStatus.of(claude(100), a, now: now)
        XCTAssertEqual(status, .atLimit)
        let s = status.sentence(usage: claude(100), assessment: a, now: now)
        XCTAssertTrue(s.hasPrefix("At the weekly limit."), s)
        XCTAssertTrue(s.contains("in 1d 12h"), s)
    }

    func testHeadlineSaysAtItsLimit() {
        let a = BurnAssessment.unknown
        XCTAssertEqual(UsageSummary.headline([(claude(100), a)], now: now), "Claude is at its weekly limit.")
    }

    func testAStaleFullReadingIsStaleNotAtLimit() {
        XCTAssertEqual(PaceStatus.of(claude(100, readAgo: 2 * 86_400), .unknown, now: now),
                       .stale(now.addingTimeInterval(-2 * 86_400)))
    }
}
