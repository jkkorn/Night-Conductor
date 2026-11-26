import XCTest

@testable import NightConductor

/// ChatGPT usage read from the account itself (via the official Codex
/// app-server), so cloud runs such as Conductor Build count, not just Codex
/// runs that happened to write files on this Mac.
final class CodexAccountReaderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_600_000)

    private func response(_ result: String) -> Data {
        Data(#"{"id":1,"result":{}}"#.utf8) + Data("\n".utf8)
            + Data(#"{"method":"some/notification","params":{}}"#.utf8) + Data("\n".utf8)
            // app-server sends one JSON message per line
            + Data(#"{"id":2,"result":\#(result.replacingOccurrences(of: "\n", with: " "))}"#.utf8)
            + Data("\n".utf8)
    }

    func testParsesWeeklyUsageFromAccount() throws {
        let data = response(#"""
            {"rateLimits":{"primary":{"usedPercent":51,"windowDurationMins":10080,"resetsAt":1796062982},
             "secondary":null,"planType":"pro"},
             "rateLimitResetCredits":{"availableCount":3,"credits":[]}}
            """#)
        let usage = try XCTUnwrap(CodexAccountReader.parse(data, now: now))
        XCTAssertEqual(usage.provider, .chatgpt)
        XCTAssertEqual(usage.weekly.utilization, 51)
        XCTAssertEqual(usage.weekly.resetsAt, Date(timeIntervalSince1970: 1_796_062_982))
        XCTAssertEqual(usage.windowLength, 10080 * 60)
        XCTAssertEqual(usage.plan, "Pro")
        XCTAssertEqual(usage.readAt, now)
        XCTAssertEqual(usage.freeResetsAvailable, 3)
        XCTAssertFalse(usage.isResetSinceReading)
    }

    func testPicksTheLongerWindowWhenBothArePresent() throws {
        let data = response(#"""
            {"rateLimits":{"primary":{"usedPercent":80,"windowDurationMins":300,"resetsAt":1795601000},
             "secondary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":1796062982},"planType":"plus"}}
            """#)
        let usage = try XCTUnwrap(CodexAccountReader.parse(data, now: now))
        XCTAssertEqual(usage.weekly.utilization, 40)
        XCTAssertEqual(usage.freeResetsAvailable, 0)
    }

    func testErrorsAndGarbageGiveNothing() {
        XCTAssertNil(CodexAccountReader.parse(Data(#"{"id":2,"error":{"message":"not logged in"}}"#.utf8), now: now))
        XCTAssertNil(CodexAccountReader.parse(Data("not json\n".utf8), now: now))
        XCTAssertNil(CodexAccountReader.parse(response(#"{"rateLimits":null}"#), now: now))
    }

    func testAbsurdValuesAreBounded() throws {
        let data = response(#"""
            {"rateLimits":{"primary":{"usedPercent":1e9,"windowDurationMins":10080,"resetsAt":1e300},"planType":"pro"}}
            """#)
        let usage = try XCTUnwrap(CodexAccountReader.parse(data, now: now))
        XCTAssertEqual(usage.weekly.utilization, 100)
        XCTAssertNil(usage.weekly.resetsAt)
    }
}

/// Talks to the real Codex and account. Opt-in: NC_LIVE=1 swift test --filter CodexAccountLiveTests
final class CodexAccountLiveTests: XCTestCase {
    func testReadsTheRealAccount() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NC_LIVE"] == "1", "live check is opt-in")
        let started = Date()
        let usage = try XCTUnwrap(CodexAccountReader.read(), "no reading from the account")
        print("LIVE ChatGPT: \(Int(usage.weekly.utilization))% used, plan \(usage.plan ?? "?"), resets \(String(describing: usage.weekly.resetsAt)), free resets \(usage.freeResetsAvailable), took \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
    }
}
