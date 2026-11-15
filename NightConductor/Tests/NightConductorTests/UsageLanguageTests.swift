import XCTest

@testable import NightConductor

/// One language everywhere: percentages are always "used", never "left",
/// "remaining" or a bare number, matching how Claude words its own usage page.
final class UsageLanguageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var reset: Date { now.addingTimeInterval(3 * 86_400) }

    private func usage(_ pct: Double, source: String = "Claude Code") -> ProviderUsage {
        ProviderUsage(provider: .claude, source: source, plan: nil,
                      weekly: UsageWindow(utilization: pct, resetsAt: reset), readAt: now)
    }

    private func assessment(even: Double? = 50, runOut: Date? = nil, hot: Bool = false,
                            recent: Double? = nil, usual: Double? = nil) -> BurnAssessment {
        BurnAssessment(evenPacePercent: even, runsOutAt: runOut, recentRate: recent,
                       usualRate: usual, isBurningHot: hot)
    }

    func testPercentLabelSaysUsed() {
        XCTAssertEqual(UsageWording.used(15), "15% used")
        XCTAssertEqual(UsageWording.used(51.94), "52% used")
    }

    func testOnTrackSentenceMatchesClaudesPhrasing() {
        let s = PaceStatus.of(usage(20), assessment()).sentence(usage: usage(20), assessment: assessment(), now: now)
        XCTAssertTrue(s.hasPrefix("On track."), s)
        XCTAssertTrue(s.contains("reset with room to spare"), s)
    }

    func testEverySentenceAvoidsRemainingLanguageAndDashes() {
        let cases: [(ProviderUsage, BurnAssessment)] = [
            (usage(20), assessment()),
            (usage(70), assessment()),
            (usage(70), assessment(runOut: now.addingTimeInterval(86_400))),
            (usage(70), assessment(hot: true, recent: 9, usual: 3)),
            (usage(70), assessment(even: nil)),
            (usage(70).normalized(now: reset.addingTimeInterval(60)), assessment()),
        ]
        for (u, a) in cases {
            let s = PaceStatus.of(u, a).sentence(usage: u, assessment: a, now: now)
            XCTAssertFalse(s.isEmpty)
            for banned in ["left", "remaining", "\u{2014}", "\u{2013}"] {
                XCTAssertFalse(s.localizedCaseInsensitiveContains(banned), "\(banned) in: \(s)")
            }
        }
    }

    // The screenshot case: 30% used two days in, straight-line math says you'd
    // run out 8 hours before a reset five days away. That's "close", not red.
    func testRunOutOnlyWarnsWhenItIsADayOrMoreEarly() {
        let start = now.addingTimeInterval(-48 * 3600)
        let chatgpt = ProviderUsage(provider: .chatgpt, source: "Codex", plan: "Pro",
                                    weekly: UsageWindow(utilization: 30, resetsAt: start.addingTimeInterval(168 * 3600)),
                                    readAt: now)
        let a = BurnForecast.assess(usage: chatgpt, samples: [], now: now)
        XCTAssertNil(a.runsOutAt, "8h short of a reset 5 days out must not raise a run-out warning")
        XCTAssertEqual(PaceStatus.of(chatgpt, a), .close)
        let s = PaceStatus.close.sentence(usage: chatgpt, assessment: a, now: now)
        XCTAssertTrue(s.hasPrefix("On track, but close."), s)
    }

    func testRunOutSentenceSaysWhenAndHowEarly() {
        let runOut = now.addingTimeInterval(86_400)
        let a = assessment(runOut: runOut)
        let s = PaceStatus.runsOut(runOut).sentence(usage: usage(70), assessment: a, now: now)
        XCTAssertTrue(s.contains("use it all by"), s)
        XCTAssertTrue(s.contains("about 2 days before it resets"), s)
        XCTAssertFalse(s.contains("100% used"), s)
        XCTAssertFalse(s.contains(", before"), s)
    }

    func testHotSentenceQuotesUsedAmount() {
        let a = assessment(hot: true, recent: 9, usual: 3)
        let s = PaceStatus.of(usage(70), a).sentence(usage: usage(70), assessment: a, now: now)
        XCTAssertTrue(s.contains("9% used in the last hour"), s)
    }

    func testClaudePlanLabelFromCredential() {
        XCTAssertEqual(UsageClient.planLabel(subscriptionType: "max", rateLimitTier: "default_claude_max_20x"), "Max 20x")
        XCTAssertEqual(UsageClient.planLabel(subscriptionType: "max", rateLimitTier: "default_claude_max_5x"), "Max 5x")
        XCTAssertEqual(UsageClient.planLabel(subscriptionType: "pro", rateLimitTier: nil), "Pro")
        XCTAssertNil(UsageClient.planLabel(subscriptionType: nil, rateLimitTier: nil))
    }

    func testPolicyReasonsSayUsed() {
        let snap = UsageSnapshot(fiveHour: nil,
                                 sevenDay: UsageWindow(utilization: 95, resetsAt: reset), fetchedAt: now)
        let d = Policy.budgetAllows(usage: snap, config: PolicyConfig(), now: now)
        XCTAssertTrue(d.reason.contains("95% used"), d.reason)
    }
}
