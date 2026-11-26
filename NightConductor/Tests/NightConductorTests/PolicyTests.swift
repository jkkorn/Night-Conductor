import XCTest

@testable import NightConductor

final class PolicyTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(hour: Int, day: Int = 11) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour))!
    }

    private func snapshot(
        fiveHour: Double? = nil, weekly: Double = 10, resetsInDays: Double = 3, now: Date
    ) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: fiveHour.map { UsageWindow(utilization: $0, resetsAt: nil) },
            sevenDay: UsageWindow(
                utilization: weekly,
                resetsAt: now.addingTimeInterval(resetsInDays * 86_400)
            ),
            fetchedAt: now
        )
    }

    private func decide(_ usage: UsageSnapshot, at now: Date, config: PolicyConfig = PolicyConfig()) -> Decision {
        Policy.shouldResume(usage: usage, config: config, now: now)
    }

    // There is no night: the same healthy week resumes at noon and at 2am.
    func testAnyHourResumesWhenTheWeekHasRoom() {
        for hour in [2, 12, 18] {
            let now = date(hour: hour)
            let d = decide(snapshot(now: now), at: now)
            XCTAssertTrue(d.resume, "hour \(hour): \(d.reason)")
            XCTAssertEqual(d.state, .resuming)
        }
    }

    // At the real limit, waiting for the reset is the plan: calm, and it
    // says when the reset is.
    func testAtTheLimitWaitsForTheResetCalmly() {
        let now = date(hour: 12)
        let d = decide(snapshot(weekly: 100, resetsInDays: 0.5, now: now), at: now)
        XCTAssertFalse(d.resume)
        XCTAssertEqual(d.state, .waitingForReset)
        XCTAssertTrue(d.reason.contains("weekly limit"), d.reason)
        XCTAssertTrue(d.reason.contains("in 12h"), d.reason)
    }

    func testStopLineLeavesTheRestOfTheWeekToYou() {
        let now = date(hour: 12)
        let d = decide(snapshot(weekly: 92, resetsInDays: 0.2, now: now), at: now)
        XCTAssertFalse(d.resume)
        XCTAssertEqual(d.state, .waitingForReset)
        XCTAssertTrue(d.reason.contains("past your 90% stop"), d.reason)
    }

    func testStopLineIsConfigurable() {
        let now = date(hour: 12)
        var config = PolicyConfig()
        config.weeklyCeiling = 80
        XCTAssertFalse(decide(snapshot(weekly: 82, resetsInDays: 0.2, now: now), at: now, config: config).resume)
    }

    func testStopLineIsClampedFromDefaults() {
        let suite = "PolicyTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set(5.0, forKey: "weeklyCeiling")
        XCTAssertEqual(PolicyConfig.fromDefaults(d).weeklyCeiling, 50)
        d.set(400.0, forKey: "weeklyCeiling")
        XCTAssertEqual(PolicyConfig.fromDefaults(d).weeklyCeiling, 100)
    }

    // A plan that still reports a short window: its ceiling still holds.
    func testFiveHourCeilingHoldsWhenThePlanHasOne() {
        let now = date(hour: 2)
        let d = decide(snapshot(fiveHour: 90, now: now), at: now)
        XCTAssertFalse(d.resume)
        XCTAssertTrue(d.reason.contains("5-hour"))
    }

    // Weekly-only plans (the API sends `five_hour: null`): only weekly gates.
    func testNoFiveHourWindowSkipsShortWindowGates() {
        let now = date(hour: 5)
        let d = decide(snapshot(fiveHour: nil, now: now), at: now)
        XCTAssertTrue(d.resume, d.reason)
        XCTAssertFalse(d.reason.contains("5-hour"))
    }

    func testBurningTooFastHoldsAndSaysItLifts() {
        let now = date(hour: 2)
        let d = decide(snapshot(weekly: 70, resetsInDays: 5, now: now), at: now)
        XCTAssertFalse(d.resume)
        XCTAssertEqual(d.state, .holding)
        XCTAssertTrue(d.reason.contains("so the week lasts"), d.reason)
    }

    // Pacing boundary: 3.5 days left -> 50% of the week elapsed -> allowed =
    // 50 + pacingMargin(15) = 65%. At or under that we resume; just over holds.
    func testWeeklyPacingBoundary() {
        let now = date(hour: 2)
        XCTAssertTrue(decide(snapshot(weekly: 64, resetsInDays: 3.5, now: now), at: now).resume)
        XCTAssertFalse(decide(snapshot(weekly: 66, resetsInDays: 3.5, now: now), at: now).resume)
    }

    // Right after a reset the week is fresh, and pace allows the first 15%.
    func testFreshWeekAfterResetResumes() {
        let now = date(hour: 2)
        XCTAssertTrue(decide(snapshot(weekly: 0, resetsInDays: 7, now: now), at: now).resume)
    }

    func testHighUsageNearResetResumes() {
        let now = date(hour: 2)
        XCTAssertTrue(decide(snapshot(weekly: 70, resetsInDays: 0.5, now: now), at: now).resume)
    }

    func testISOParsingHandlesBothPrecisions() {
        XCTAssertNotNil(ISO.parse("2026-06-12T05:00:00.772121+00:00")) // usage API
        XCTAssertNotNil(ISO.parse("2026-06-09T03:42:18.186Z")) // Conductor DB
    }
}

final class UIResumerTests: XCTestCase {
    func testNormalizeMatchesConductorSidebarLabels() {
        // "new-york" workspace shows as "New york" in the sidebar
        XCTAssertEqual(UIResumer.normalize("new-york"), "new york")
        XCTAssertEqual(UIResumer.normalize("New york"), "new york")
        // separators unified
        XCTAssertEqual(UIResumer.normalize("my_cool-workspace"), "my cool workspace")
    }

    func testSidebarLabelWithAppendedPRTitleStillPrefixMatches() {
        // "yokohama" shows as "Yokohama pr1 funnel fixes +977 -205"
        let ws = UIResumer.normalize("yokohama")
        let sidebar = UIResumer.normalize("Yokohama pr1 funnel fixes +977 -205")
        XCTAssertTrue(sidebar.hasPrefix(ws))
    }
}

final class ResumeLedgerTests: XCTestCase {
    private func saoPaulo() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Sao_Paulo")! // UTC-3
        return c
    }

    func testDayKeyIsTheLocalDateNotUTC() {
        // 22:30 local in UTC-3 is already the next day in UTC; the key must
        // follow the local day, or the daily caps reset in the evening.
        let cal = saoPaulo()
        let evening = cal.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 22, minute: 30))!
        XCTAssertEqual(ResumeLedger.currentKey(now: evening, calendar: cal), "2026-06-10")
        let next = cal.date(from: DateComponents(year: 2026, month: 6, day: 11, hour: 0, minute: 30))!
        XCTAssertEqual(ResumeLedger.currentKey(now: next, calendar: cal), "2026-06-11")
    }

    func testRecordingIsImmutableAndCounts() {
        let base = ResumeLedger(key: "2026-06-10", counts: [:])
        let after = base.recordingSuccess("s1").recordingSuccess("s1").recordingSuccess("s2")
        XCTAssertEqual(base.total, 0) // original unchanged
        XCTAssertEqual(after.count(for: "s1"), 2)
        XCTAssertEqual(after.total, 3)
    }
}

final class ISOSpaceTests: XCTestCase {
    func testParsesSpaceSeparatedTimestamp() {
        // Regression (M3): a space separator must still parse, else the
        // 48h staleness guard would be skipped.
        XCTAssertNotNil(ISO.parse("2026-06-09 03:42:18.186Z"))
        XCTAssertNotNil(ISO.parse("2026-06-09 03:42:18Z"))
    }
}
