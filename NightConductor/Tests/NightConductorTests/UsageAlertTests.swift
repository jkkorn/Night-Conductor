import XCTest

@testable import NightConductor

final class UsageAlertTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let reset = Date(timeIntervalSince1970: 1_800_000_000 + 5 * 86_400)

    private var usage: ProviderUsage {
        ProviderUsage(provider: .chatgpt, source: "Codex", plan: "Pro",
                      weekly: UsageWindow(utilization: 71, resetsAt: reset), readAt: now)
    }

    private func assessment(runOut: Bool, hot: Bool) -> BurnAssessment {
        BurnAssessment(evenPacePercent: 30,
                       runsOutAt: runOut ? now.addingTimeInterval(30 * 3600) : nil,
                       recentRate: hot ? 9 : 1, usualRate: 3, isBurningHot: hot)
    }

    func testRaisesBothAlertsWhenEnabled() {
        let alerts = UsageAlerts.candidates(usage: usage, assessment: assessment(runOut: true, hot: true),
                                            settings: AlertSettings(burnHot: true, runOut: true), now: now)
        XCTAssertEqual(Set(alerts.map(\.kind)), [.burningHot, .runOutBeforeReset])
    }

    func testRespectsSettings() {
        let alerts = UsageAlerts.candidates(usage: usage, assessment: assessment(runOut: true, hot: true),
                                            settings: AlertSettings(burnHot: false, runOut: false), now: now)
        XCTAssertTrue(alerts.isEmpty)
    }

    func testCopyNamesProviderAndHasNoDashes() throws {
        let alerts = UsageAlerts.candidates(usage: usage, assessment: assessment(runOut: true, hot: true),
                                            settings: AlertSettings(burnHot: true, runOut: true), now: now)
        for a in alerts {
            XCTAssertTrue(a.title.contains("ChatGPT"))
            XCTAssertFalse((a.title + a.body).contains("\u{2014}"), "no em dashes in copy")
            XCTAssertFalse((a.title + a.body).contains("\u{2013}"), "no en dashes in copy")
        }
    }

    func testRunOutAlertsOncePerWindow() {
        let a = UsageAlerts.candidates(usage: usage, assessment: assessment(runOut: true, hot: false),
                                       settings: AlertSettings(burnHot: true, runOut: true), now: now)
        let sent = UsageAlerts.marking(a, sent: [:], now: now)
        let later = now.addingTimeInterval(2 * 86_400)
        XCTAssertTrue(UsageAlerts.unsent(a, sent: sent, now: later).isEmpty)
    }

    func testHotAlertRearmsAfterCooldown() {
        let a = UsageAlerts.candidates(usage: usage, assessment: assessment(runOut: false, hot: true),
                                       settings: AlertSettings(burnHot: true, runOut: true), now: now)
        let sent = UsageAlerts.marking(a, sent: [:], now: now)
        XCTAssertTrue(UsageAlerts.unsent(a, sent: sent, now: now.addingTimeInterval(3600)).isEmpty)
        XCTAssertEqual(UsageAlerts.unsent(a, sent: sent, now: now.addingTimeInterval(4 * 3600)).count, 1)
    }

    func testNoAlertsForAResetReading() {
        let stale = ProviderUsage(provider: .grok, source: "Grok Bot", plan: nil,
                                  weekly: UsageWindow(utilization: 99, resetsAt: now.addingTimeInterval(-60)),
                                  readAt: now.addingTimeInterval(-3600))
        let alerts = UsageAlerts.candidates(usage: stale, assessment: assessment(runOut: true, hot: true),
                                            settings: AlertSettings(burnHot: true, runOut: true), now: now)
        XCTAssertTrue(alerts.isEmpty)
    }
}

final class PaceStatusTests: XCTestCase {
    private func usage(_ pct: Double) -> ProviderUsage {
        ProviderUsage(provider: .claude, source: "Claude Code", plan: nil,
                      weekly: UsageWindow(utilization: pct, resetsAt: Date().addingTimeInterval(86_400)),
                      readAt: Date())
    }
    private func a(even: Double?, runOut: Date? = nil, hot: Bool = false) -> BurnAssessment {
        BurnAssessment(evenPacePercent: even, runsOutAt: runOut, recentRate: nil, usualRate: nil, isBurningHot: hot)
    }

    func testPriorityHotThenRunOutThenPace() {
        let soon = Date().addingTimeInterval(3600)
        XCTAssertEqual(PaceStatus.of(usage(50), a(even: 50, runOut: soon, hot: true)), .burningHot)
        XCTAssertEqual(PaceStatus.of(usage(50), a(even: 50, runOut: soon)), .runsOut(soon))
        XCTAssertEqual(PaceStatus.of(usage(65), a(even: 50)), .ahead)
        XCTAssertEqual(PaceStatus.of(usage(55), a(even: 50)), .close)   // a bit over even pace
        XCTAssertEqual(PaceStatus.of(usage(45), a(even: 50)), .onPace)
        XCTAssertEqual(PaceStatus.of(usage(55), a(even: nil)), .unknown)
    }
}
