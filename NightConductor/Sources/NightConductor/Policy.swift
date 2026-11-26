import Foundation

/// Budget policy: the brain. Claude and ChatGPT plans are weekly-only, so a
/// session stalled on the limit can't run again until the week resets, at
/// whatever hour that is. There is no "night": the gate is the week itself.
///
/// Unattended resumes need all three:
///   1. you're under your stop line ("keep the last 10% for me"),
///   2. you aren't spending the week faster than it's passing (with a margin),
///   3. a fresh usage reading (checked by the caller; no reading, no resume).
enum Policy {
    static func daysUntilWeeklyReset(_ usage: UsageSnapshot, now: Date) -> Double {
        guard let resetsAt = usage.sevenDay.resetsAt else { return 0 }
        return max(0, resetsAt.timeIntervalSince(now) / 86_400)
    }

    /// "Friday 01:59 (in 14h)", or nil when the API didn't say.
    static func resetPhrase(_ usage: UsageSnapshot, now: Date) -> String? {
        guard let resets = usage.sevenDay.resetsAt, resets > now else { return nil }
        let day = resets.formatted(.dateTime.weekday(.wide).hour().minute())
        return "\(day) (\(ResetWatch.countdown(to: resets, now: now)))"
    }

    static func shouldResume(usage: UsageSnapshot, config: PolicyConfig, now: Date) -> Decision {
        let used = usage.sevenDay.utilization
        let reset = resetPhrase(usage, now: now)
        let afterReset = reset.map { " Resumes after the reset, \($0)." } ?? " Resumes after the weekly reset."

        // A plan that still has a short window: respect it too.
        if let fiveHour = usage.fiveHour, fiveHour.utilization >= config.fiveHourCeiling {
            return Decision(
                resume: false,
                reason: "5-hour window: \(Int(fiveHour.utilization))% used, past \(Int(config.fiveHourCeiling))%.",
                state: .holding
            )
        }

        // At the real limit: nothing can run, and that's not a problem to fix.
        // Waiting for the reset is the plan, said calmly.
        if used >= 100 {
            return Decision(
                resume: false,
                reason: "Claude is at its weekly limit." + afterReset,
                state: .waitingForReset
            )
        }

        if used >= config.weeklyCeiling {
            return Decision(
                resume: false,
                reason: "\(Int(used))% used, past your \(Int(config.weeklyCeiling))% stop, "
                    + "so the rest of the week stays yours." + afterReset,
                state: .waitingForReset
            )
        }

        // Pace: don't let unattended work get ahead of the week. At 70% with
        // five days left, resuming now would leave you short on Thursday.
        let daysLeft = daysUntilWeeklyReset(usage, now: now)
        let elapsedPct = (1.0 - min(daysLeft, 7.0) / 7.0) * 100.0
        if used > elapsedPct + config.pacingMargin {
            return Decision(
                resume: false,
                reason: "Holding so the week lasts: \(Int(used))% used with "
                    + String(format: "%.1f", daysLeft) + " days to go. "
                    + "This lifts as the week catches up, or at the reset.",
                state: .holding
            )
        }

        let tail = reset.map { ", resets \($0)" } ?? ""
        return Decision(
            resume: true,
            reason: "Room to resume: \(Int(used))% used\(tail).",
            state: .resuming
        )
    }
}
