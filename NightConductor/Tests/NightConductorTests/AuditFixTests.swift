import XCTest

@testable import NightConductor

/// The design/product audit fixes: one summary line, honest stale readings,
/// a menu bar that shows what needs attention, and plain night-watch copy.
final class AuditFixTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func usage(_ p: ProviderID, _ pct: Double, readHoursAgo: Double = 0) -> ProviderUsage {
        ProviderUsage(provider: p, source: p.displayName, plan: nil,
                      weekly: UsageWindow(utilization: pct, resetsAt: now.addingTimeInterval(3 * 86_400)),
                      readAt: now.addingTimeInterval(-readHoursAgo * 3600))
    }

    private func a(even: Double = 50, runOut: Date? = nil, hot: Bool = false) -> BurnAssessment {
        BurnAssessment(evenPacePercent: even, runsOutAt: runOut, recentRate: hot ? 9 : nil,
                       usualRate: hot ? 3 : nil, isBurningHot: hot)
    }

    // MARK: summary line (D2)

    func testAllOnTrackIsOneShortLine() {
        let rows = [(usage(.claude, 10), a()), (usage(.chatgpt, 20), a()), (usage(.grok, 30), a())]
        XCTAssertEqual(UsageSummary.headline(rows, now: now), "All three on track.")
    }

    func testProblemsComeFirstThenTheRest() {
        let rows = [(usage(.claude, 10), a()),
                    (usage(.chatgpt, 70), a(runOut: now.addingTimeInterval(86_400))),
                    (usage(.grok, 30), a())]
        XCTAssertEqual(UsageSummary.headline(rows, now: now),
                       "ChatGPT will run out before it resets. Claude and Grok are on track.")
    }

    func testCloseAndStaleAreNamed() {
        let rows = [(usage(.claude, 55), a()), (usage(.grok, 30, readHoursAgo: 48), a())]
        XCTAssertEqual(UsageSummary.headline(rows, now: now),
                       "Claude is cutting it close. Grok\u{2019}s reading is out of date.")
    }

    // MARK: stale readings (P2)

    func testReadingOlderThanADayIsStale() {
        let old = usage(.grok, 52, readHoursAgo: 48)
        XCTAssertEqual(PaceStatus.of(old, a(), now: now), .stale(old.readAt))
        let s = PaceStatus.stale(old.readAt).sentence(usage: old, assessment: a(), now: now)
        XCTAssertTrue(s.hasPrefix("Last reading "), s)
        XCTAssertTrue(s.contains("Open Grok to refresh."), s)
    }

    func testNoAlertsFromStaleReadings() {
        let old = usage(.grok, 90, readHoursAgo: 30)
        let alerts = UsageAlerts.candidates(usage: old, assessment: a(runOut: now.addingTimeInterval(86_400), hot: true),
                                            settings: AlertSettings(burnHot: true, runOut: true), now: now)
        XCTAssertTrue(alerts.isEmpty)
    }

    // MARK: menu bar shows what needs attention (P3)

    func testMenuBarPicksTheMostUrgentAccount() {
        let rows = [(usage(.claude, 15), a()),
                    (usage(.chatgpt, 30), a(runOut: now.addingTimeInterval(86_400))),
                    (usage(.grok, 52), a())]
        XCTAssertEqual(UsageSummary.mostUrgent(rows, now: now)?.provider, .chatgpt)
    }

    func testMenuBarStaysOnClaudeWhenNothingIsWrong() {
        let rows = [(usage(.claude, 15), a()), (usage(.chatgpt, 55), a())] // "close" is not urgent
        XCTAssertNil(UsageSummary.mostUrgent(rows, now: now))
    }

    // MARK: copy (D6)

    func testNightWatchStandbyIsPlain() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let noon = cal.date(from: DateComponents(year: 2026, month: 6, day: 11, hour: 12))!
        let snap = UsageSnapshot(fiveHour: nil,
                                 sevenDay: UsageWindow(utilization: 10, resetsAt: noon.addingTimeInterval(86_400 * 3)),
                                 fetchedAt: noon)
        let d = Policy.shouldResume(usage: snap, config: PolicyConfig(), now: noon, calendar: cal)
        XCTAssertEqual(d.reason, "Night watch starts at 23:00. It resumes stalled sessions while you sleep.")
    }

    // MARK: setup checklist includes alerts (P4)

    func testSetupCardShowsUntilNotificationsAreAllowed() {
        XCTAssertTrue(SetupStatus.shouldShow(accessibilityGranted: true, dismissed: false,
                                             isScreenshot: false, notificationsAllowed: false))
        XCTAssertFalse(SetupStatus.shouldShow(accessibilityGranted: true, dismissed: false,
                                              isScreenshot: false, notificationsAllowed: true))
    }

    // MARK: free limit resets (user can't be done automatically, so point at them)

    func testSuggestsAFreeResetOnlyWhenClaudeIsNearlyOutWithTimeLeft() {
        XCTAssertTrue(UsageSummary.suggestsFreeReset(usage(.claude, 85)))
        XCTAssertFalse(UsageSummary.suggestsFreeReset(usage(.claude, 50)))
        XCTAssertFalse(UsageSummary.suggestsFreeReset(usage(.chatgpt, 95)))
        let endingSoon = ProviderUsage(provider: .claude, source: "Claude Code", plan: nil,
                                       weekly: UsageWindow(utilization: 95, resetsAt: Date().addingTimeInterval(3600)),
                                       readAt: Date())
        XCTAssertFalse(UsageSummary.suggestsFreeReset(endingSoon), "resets within hours anyway")
    }

    // MARK: Fable reset line (D4)

    func testSubLimitHidesResetWhenSameAsTheWeek() {
        let week = now.addingTimeInterval(3 * 86_400)
        XCTAssertFalse(UsageSummary.showsOwnReset(week.addingTimeInterval(1800), weekly: week))
        XCTAssertTrue(UsageSummary.showsOwnReset(week.addingTimeInterval(-86_400), weekly: week))
    }
}
