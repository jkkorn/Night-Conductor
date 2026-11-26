import Foundation

/// The cross-provider read: one headline for the top of "Your usage" (so
/// three cards don't each repeat "On track"), which account the menu bar
/// should show, and small presentation rules. Pure, so it's all testable.
enum UsageSummary {
    typealias Row = (usage: ProviderUsage, assessment: BurnAssessment)

    /// Readings older than this are shown as out of date, not forecast from.
    static let staleAfter: TimeInterval = 24 * 3600

    /// "All three on track." / "ChatGPT will run out before it resets.
    /// Claude and Grok are on track." Problems first, then the rest.
    static func headline(_ rows: [Row], now: Date = Date()) -> String {
        var problems: [String] = []
        var onTrack: [String] = []
        for row in rows {
            let name = row.usage.provider.displayName
            switch PaceStatus.of(row.usage, row.assessment, now: now) {
            case .onPace, .unknown: onTrack.append(name)
            case .atLimit: problems.append("\(name) is at its weekly limit.")
            case .close: problems.append("\(name) is cutting it close.")
            case .ahead: problems.append("\(name) is ahead of pace.")
            case .runsOut: problems.append("\(name) will run out before it resets.")
            case .burningHot: problems.append("\(name) is burning fast.")
            case .stale: problems.append("\(name)\u{2019}s reading is out of date.")
            case .resetSinceReading: problems.append("\(name) reset since its last reading.")
            }
        }
        guard !problems.isEmpty else { return allOnTrack(count: onTrack.count) }
        guard !onTrack.isEmpty else { return problems.joined(separator: " ") }
        let verb = onTrack.count == 1 ? "is" : "are"
        return (problems + ["\(list(onTrack)) \(verb) on track."]).joined(separator: " ")
    }

    /// The account the menu bar should show instead of Claude: only one that
    /// actually needs attention (ahead, running out, burning fast).
    static func mostUrgent(_ rows: [Row], now: Date = Date()) -> ProviderUsage? {
        rows.map { (row: $0, rank: urgency(PaceStatus.of($0.usage, $0.assessment, now: now))) }
            .filter { $0.rank >= 3 }
            .max { ($0.rank, $0.row.usage.weekly.utilization) < ($1.rank, $1.row.usage.weekly.utilization) }?
            .row.usage
    }

    static func urgency(_ status: PaceStatus) -> Int {
        switch status {
        case .atLimit: return 6
        case .burningHot: return 5
        case .runsOut: return 4
        case .ahead: return 3
        case .close: return 2
        case .onPace: return 1
        case .stale, .resetSinceReading, .unknown: return 0
        }
    }

    /// A sub-limit (Fable) only needs its own "Resets …" line when it resets
    /// at a different time than the week it sits under.
    static func showsOwnReset(_ subReset: Date?, weekly: Date?) -> Bool {
        guard let subReset else { return false }
        guard let weekly else { return true }
        return abs(subReset.timeIntervalSince(weekly)) > 2 * 3600
    }

    /// Claude's free limit resets can't be read or redeemed safely from here
    /// (they live behind the website session), so point at them at the moment
    /// they matter: nearly out, with real time left in the week.
    static func suggestsFreeReset(_ usage: ProviderUsage, now: Date = Date()) -> Bool {
        guard usage.provider == .claude, usage.weekly.utilization >= 80,
              let resets = usage.weekly.resetsAt else { return false }
        return resets.timeIntervalSince(now) > 12 * 3600
    }

    static let claudeUsagePage = URL(string: "https://claude.ai/settings/usage")!

    private static func allOnTrack(count: Int) -> String {
        switch count {
        case 0: return "Reading your usage…"
        case 1: return "On track."
        case 2: return "Both on track."
        case 3: return "All three on track."
        default: return "All \(count) on track."
        }
    }

    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}
