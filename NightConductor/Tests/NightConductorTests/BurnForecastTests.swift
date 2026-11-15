import XCTest

@testable import NightConductor

final class BurnForecastTests: XCTestCase {
    private let hour: TimeInterval = 3600
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A weekly window that started `elapsedHours` ago.
    private func usage(_ pct: Double, elapsedHours: Double, provider: ProviderID = .claude) -> ProviderUsage {
        let start = now.addingTimeInterval(-elapsedHours * hour)
        return ProviderUsage(provider: provider, source: "test", plan: nil,
                             weekly: UsageWindow(utilization: pct, resetsAt: start.addingTimeInterval(168 * hour)),
                             readAt: now)
    }

    private func sample(_ hoursAgo: Double, _ pct: Double, resets: Date? = nil) -> UsageSample {
        UsageSample(at: now.addingTimeInterval(-hoursAgo * hour), percent: pct, resetsAt: resets)
    }

    // MARK: even pace

    func testEvenPaceIsElapsedFractionOfWeek() {
        XCTAssertEqual(BurnForecast.evenPacePercent(usage: usage(10, elapsedHours: 84), now: now)!, 50, accuracy: 0.01)
    }

    // MARK: "will I run out before reset?"

    func testProjectsRunOutBeforeReset() throws {
        // 60% used in 2 days → 1.25%/h → 40% left lasts 32h, reset is 120h away.
        let runOut = try XCTUnwrap(BurnForecast.projectedRunOut(usage: usage(60, elapsedHours: 48), now: now))
        XCTAssertEqual(runOut.timeIntervalSince(now) / hour, 32, accuracy: 0.1)
    }

    func testNoRunOutWhenPaceFitsTheWeek() {
        XCTAssertNil(BurnForecast.projectedRunOut(usage: usage(20, elapsedHours: 84), now: now))
    }

    func testNoProjectionTooEarlyInTheWindow() {
        // 10% in the first 2 hours is just a busy morning, not a forecast.
        XCTAssertNil(BurnForecast.projectedRunOut(usage: usage(10, elapsedHours: 2), now: now))
    }

    func testAlreadyOutHasNoFutureRunOut() {
        XCTAssertNil(BurnForecast.projectedRunOut(usage: usage(100, elapsedHours: 48), now: now))
    }

    // MARK: "am I burning more than usual?"

    func testRecentRateFromLastHour() throws {
        let samples = [sample(1.0, 40), sample(0.5, 44), sample(0, 49)]
        XCTAssertEqual(try XCTUnwrap(BurnForecast.recentRate(samples: samples, now: now)), 9, accuracy: 0.01)
    }

    func testRecentRateNeedsEnoughHistory() {
        // Only 10 minutes of samples: too little to call a rate.
        XCTAssertNil(BurnForecast.recentRate(samples: [sample(0.16, 40), sample(0, 42)], now: now))
    }

    func testRecentRateIgnoresWindowReset() {
        // A reset (percent drops) is not negative burn.
        let samples = [sample(1.0, 90), sample(0.5, 0), sample(0, 3)]
        XCTAssertEqual(try XCTUnwrap(BurnForecast.recentRate(samples: samples, now: now)), 3, accuracy: 0.01)
    }

    func testUsualRateAveragesOnlyActiveHours() throws {
        // Three active hours yesterday (+2, +3, +4 per hour), then idle hours.
        let samples = [
            sample(30, 10), sample(29, 12), sample(28, 15), sample(27, 19),
            sample(26, 19), sample(25, 19),
        ]
        XCTAssertEqual(try XCTUnwrap(BurnForecast.usualActiveRate(samples: samples, now: now)), 3, accuracy: 0.01)
    }

    func testUsualRateNilWithoutEnoughActiveHours() {
        XCTAssertNil(BurnForecast.usualActiveRate(samples: [sample(30, 10), sample(29, 12)], now: now))
    }

    func testHotWhenWellAboveUsual() {
        XCTAssertTrue(BurnForecast.isBurningHot(recent: 9, usual: 3))
        XCTAssertFalse(BurnForecast.isBurningHot(recent: 3.5, usual: 3))
    }

    func testHotNeedsAMeaningfulAbsoluteRate() {
        // 3x of a tiny habit is still a tiny burn: no alert.
        XCTAssertFalse(BurnForecast.isBurningHot(recent: 1.5, usual: 0.5))
    }

    func testHotFallsBackWithoutHistory() {
        XCTAssertTrue(BurnForecast.isBurningHot(recent: 12, usual: nil))
        XCTAssertFalse(BurnForecast.isBurningHot(recent: 2, usual: nil))
    }

    // User-configurable sensitivity: each preset moves the multiple of your
    // usual pace, the absolute floor and the no-history fallback together.
    func testSensitivityPresetsAreOrdered() {
        let sensitive = BurnSensitivity.sensitive.threshold
        let balanced = BurnSensitivity.balanced.threshold
        let relaxed = BurnSensitivity.relaxed.threshold
        XCTAssertLessThan(sensitive.multiple, balanced.multiple)
        XCTAssertLessThan(balanced.multiple, relaxed.multiple)
        XCTAssertLessThan(sensitive.floor, relaxed.floor)
        XCTAssertLessThan(sensitive.withoutHistory, relaxed.withoutHistory)
    }

    func testSameBurnHotOnlyForMoreSensitiveSettings() {
        // 5%/h against a usual 3%/h: 1.7x.
        XCTAssertTrue(BurnForecast.isBurningHot(recent: 5, usual: 3, threshold: BurnSensitivity.sensitive.threshold))
        XCTAssertFalse(BurnForecast.isBurningHot(recent: 5, usual: 3, threshold: BurnSensitivity.balanced.threshold))
        XCTAssertFalse(BurnForecast.isBurningHot(recent: 5, usual: 3, threshold: BurnSensitivity.relaxed.threshold))
    }

    func testRelaxedIgnoresWhatBalancedFlags() {
        XCTAssertTrue(BurnForecast.isBurningHot(recent: 7, usual: nil, threshold: BurnSensitivity.balanced.threshold))
        XCTAssertFalse(BurnForecast.isBurningHot(recent: 7, usual: nil, threshold: BurnSensitivity.relaxed.threshold))
    }

    func testAssessUsesTheGivenSensitivity() {
        let samples = [sample(1.0, 55), sample(0, 60)]  // 5%/h, no history
        let usage = usage(60, elapsedHours: 48)
        XCTAssertTrue(BurnForecast.assess(usage: usage, samples: samples, now: now,
                                          threshold: BurnSensitivity.sensitive.threshold).isBurningHot)
        XCTAssertFalse(BurnForecast.assess(usage: usage, samples: samples, now: now,
                                           threshold: BurnSensitivity.balanced.threshold).isBurningHot)
    }

    func testSensitivityDefaultsToBalancedAndPersists() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "nc-test-\(UUID())"))
        XCTAssertEqual(AlertSettings.fromDefaults(d).sensitivity, .balanced)
        d.set(BurnSensitivity.relaxed.rawValue, forKey: AlertSettings.sensitivityKey)
        XCTAssertEqual(AlertSettings.fromDefaults(d).sensitivity, .relaxed)
        d.set("nonsense", forKey: AlertSettings.sensitivityKey)
        XCTAssertEqual(AlertSettings.fromDefaults(d).sensitivity, .balanced)
    }

    func testAssessCombinesSignals() {
        let samples = [sample(1.0, 51), sample(0, 60)]
        let a = BurnForecast.assess(usage: usage(60, elapsedHours: 48), samples: samples, now: now)
        XCTAssertNotNil(a.runsOutAt)
        XCTAssertEqual(a.recentRate ?? 0, 9, accuracy: 0.01)
        XCTAssertTrue(a.isBurningHot)
    }

    // MARK: sample log

    func testSampleLogSkipsUnchangedUntilHeartbeat() {
        var log = UsageSampleLog()
        log = log.appending(sample(0.5, 10), for: .claude)
        log = log.appending(sample(0.4, 10), for: .claude)   // unchanged, 6 min later: skipped
        XCTAssertEqual(log.samples(for: .claude).count, 1)
        log = log.appending(sample(0.1, 10), for: .claude)   // unchanged but 24 min later: heartbeat
        log = log.appending(sample(0.05, 11), for: .claude)  // changed: kept
        XCTAssertEqual(log.samples(for: .claude).count, 3)
    }

    func testSampleLogPrunesOldSamples() {
        var log = UsageSampleLog()
        log = log.appending(sample(24 * 9, 5), for: .grok)
        log = log.appending(sample(0, 6), for: .grok)
        XCTAssertEqual(log.samples(for: .grok).map(\.percent), [6])
    }

    func testSampleLogRoundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("samples-\(UUID()).json")
        let log = UsageSampleLog().appending(sample(0, 12), for: .chatgpt)
        try log.save(to: url)
        XCTAssertEqual(UsageSampleLog.load(from: url).samples(for: .chatgpt).first?.percent, 12)
    }
}
