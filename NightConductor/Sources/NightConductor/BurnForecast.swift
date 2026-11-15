import Foundation

/// One point-in-time reading of a provider's weekly percent.
struct UsageSample: Codable, Equatable, Sendable {
    let at: Date
    let percent: Double
    let resetsAt: Date?
}

/// What the numbers say about where this week is heading.
struct BurnAssessment: Equatable, Sendable {
    /// Where you'd be right now at a perfectly even pace (the bar's tick mark).
    let evenPacePercent: Double?
    /// When you'd hit 100% at this week's pace, set ONLY if that's before reset.
    let runsOutAt: Date?
    /// Percent of the weekly budget burned in the last hour.
    let recentRate: Double?
    /// Your typical percent-per-hour in an hour when you're actually working.
    let usualRate: Double?
    let isBurningHot: Bool

    static let unknown = BurnAssessment(evenPacePercent: nil, runsOutAt: nil,
                                        recentRate: nil, usualRate: nil, isBurningHot: false)
}

/// What counts as "burning faster than usual". `multiple` × your usual busy
/// hour, never below `floor` %/h; `withoutHistory` %/h before there's enough
/// history to know your usual.
struct BurnThreshold: Equatable, Sendable {
    let multiple: Double
    let floor: Double
    let withoutHistory: Double
}

/// The user's choice in Settings, one word instead of three numbers.
enum BurnSensitivity: String, CaseIterable, Identifiable, Sendable {
    case sensitive, balanced, relaxed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sensitive: return "Sensitive"
        case .balanced: return "Balanced"
        case .relaxed: return "Relaxed"
        }
    }

    var threshold: BurnThreshold {
        switch self {
        case .sensitive: return BurnThreshold(multiple: 1.5, floor: 2, withoutHistory: 4)
        case .balanced: return BurnThreshold(multiple: 2, floor: 3, withoutHistory: 6)
        case .relaxed: return BurnThreshold(multiple: 3, floor: 5, withoutHistory: 10)
        }
    }

    /// Plain-language explanation shown under the picker.
    var explanation: String {
        let t = threshold
        let multiple = t.multiple == t.multiple.rounded() ? "\(Int(t.multiple))x" : "\(t.multiple)x"
        return "Alerts when an hour's burn hits \(multiple) your usual busy hour "
            + "(at least \(Int(t.floor))% of the week)."
    }
}

/// Pure forecasting math: no I/O, no clocks, so every branch is testable.
enum BurnForecast {
    static let hour: TimeInterval = 3600
    static let recentLookback: TimeInterval = 3600
    static let minRecentSpan: TimeInterval = 45 * 60
    /// Don't forecast from the first hours of a window: one busy morning
    /// would otherwise "project" running out by Tuesday.
    static let minElapsedForProjection: TimeInterval = 12 * 3600
    static let usualLookback: TimeInterval = 7 * 86_400
    static let minActiveHours = 3
    static let maxPairGap: TimeInterval = 2 * 3600
    /// Straight-line projections days ahead are rough. Only call it "running
    /// out" when the shortfall is at least a day; less than that is "close".
    static let runOutWarningLead: TimeInterval = 24 * 3600

    static func evenPacePercent(usage: ProviderUsage, now: Date) -> Double? {
        guard let start = usage.windowStart, usage.windowLength > 0 else { return nil }
        return SafeFile.clampPercent(now.timeIntervalSince(start) / usage.windowLength * 100)
    }

    /// Percent per hour averaged over the whole window so far (sleep included),
    /// the honest "this week's pace".
    static func averageRate(usage: ProviderUsage, now: Date) -> Double? {
        guard let start = usage.windowStart else { return nil }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= minElapsedForProjection else { return nil }
        return usage.weekly.utilization / (elapsed / hour)
    }

    static func projectedRunOut(usage: ProviderUsage, now: Date) -> Date? {
        let used = usage.weekly.utilization
        guard used < 100, let resets = usage.weekly.resetsAt,
              let rate = averageRate(usage: usage, now: now), rate > 0
        else { return nil }
        let runOut = now.addingTimeInterval((100 - used) / rate * hour)
        return runOut < resets ? runOut : nil
    }

    /// Percent burned over the last hour. Needs ~45 minutes of samples so a
    /// fresh launch doesn't read one tick as a rate. Resets don't count.
    static func recentRate(samples: [UsageSample], now: Date) -> Double? {
        let cutoff = now.addingTimeInterval(-recentLookback)
        let sorted = samples.filter { $0.at <= now }.sorted { $0.at < $1.at }
        guard let earliest = sorted.first(where: { $0.at >= cutoff.addingTimeInterval(-maxPairGap) }),
              now.timeIntervalSince(earliest.at) >= minRecentSpan
        else { return nil }
        let burned = zip(sorted, sorted.dropFirst())
            .filter { $0.1.at > cutoff }
            .reduce(0.0) { $0 + positiveDelta($1.0, $1.1) }
        let span = min(recentLookback, now.timeIntervalSince(earliest.at))
        return burned / (span / hour)
    }

    /// Your usual burn in an hour you were actually working: sum each
    /// clock-hour's increase, then average the hours that had any. Idle hours
    /// and sleep are excluded, so this is "a normal busy hour", not the week's
    /// average. The last hour is excluded so it can't define its own baseline.
    static func usualActiveRate(samples: [UsageSample], now: Date) -> Double? {
        let from = now.addingTimeInterval(-usualLookback)
        let until = now.addingTimeInterval(-recentLookback)
        let sorted = samples.filter { $0.at >= from && $0.at <= until }.sorted { $0.at < $1.at }
        var perHour: [Int: Double] = [:]
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let delta = positiveDelta(a, b)
            guard delta > 0 else { continue }
            perHour[Int(b.at.timeIntervalSince1970 / hour), default: 0] += delta
        }
        guard perHour.count >= minActiveHours else { return nil }
        return perHour.values.reduce(0, +) / Double(perHour.count)
    }

    /// Is the last hour's burn "more than usual"? `recent` and `usual` are
    /// percent of the weekly budget per hour; `usual` is nil until there are
    /// a few active hours of history. The floor keeps a multiple of a tiny
    /// habit quiet. The user picks the threshold (Settings → Alerts).
    static func isBurningHot(recent: Double, usual: Double?,
                             threshold: BurnThreshold = BurnSensitivity.balanced.threshold) -> Bool {
        guard let usual else { return recent >= threshold.withoutHistory }
        return recent >= threshold.multiple * usual && recent >= threshold.floor
    }

    static func assess(usage: ProviderUsage, samples: [UsageSample], now: Date,
                       threshold: BurnThreshold = BurnSensitivity.balanced.threshold) -> BurnAssessment {
        let recent = recentRate(samples: samples, now: now)
        let usual = usualActiveRate(samples: samples, now: now)
        return BurnAssessment(
            evenPacePercent: evenPacePercent(usage: usage, now: now),
            runsOutAt: projectedRunOut(usage: usage, now: now).flatMap { runOut in
                guard let resets = usage.weekly.resetsAt,
                      resets.timeIntervalSince(runOut) >= runOutWarningLead else { return nil }
                return runOut
            },
            recentRate: recent,
            usualRate: usual,
            isBurningHot: recent.map { isBurningHot(recent: $0, usual: usual, threshold: threshold) } ?? false
        )
    }

    /// Usage gained between two consecutive samples. A drop is a reset, not
    /// negative burn; a long gap is unknown, not a spike.
    private static func positiveDelta(_ a: UsageSample, _ b: UsageSample) -> Double {
        guard b.at.timeIntervalSince(a.at) <= maxPairGap else { return 0 }
        return max(0, b.percent - a.percent)
    }
}
