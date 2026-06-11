import Foundation

/// Budget policy — the brain. Direct port of the Python `autoconduct.policy`
/// module so the CLI and the app always agree on what "safe" means.
enum Policy {
    static func inActiveHours(hour: Int, start: Int, end: Int) -> Bool {
        if start == end { return true }
        if start < end { return start <= hour && hour < end }
        return hour >= start || hour < end
    }

    static func daysUntilWeeklyReset(_ usage: UsageSnapshot, now: Date) -> Double {
        guard let resetsAt = usage.sevenDay.resetsAt else { return 0 }
        return max(0, resetsAt.timeIntervalSince(now) / 86_400)
    }

    static func shouldResume(
        usage: UsageSnapshot,
        config: PolicyConfig,
        now: Date,
        calendar: Calendar = .current,
        ignoreActiveHours: Bool = false
    ) -> Decision {
        let hour = calendar.component(.hour, from: now)
        if !ignoreActiveHours,
           !inActiveHours(hour: hour, start: config.startHour, end: config.endHour) {
            return Decision(
                resume: false,
                reason: "Outside active hours (\(config.startHour):00–\(config.endHour):00)"
            )
        }

        if usage.fiveHour.utilization >= config.fiveHourCeiling {
            return Decision(
                resume: false,
                reason: "5-hour window at \(Int(usage.fiveHour.utilization))% "
                    + "(ceiling \(Int(config.fiveHourCeiling))%)"
            )
        }

        if usage.sevenDay.utilization >= config.weeklyCeiling {
            return Decision(
                resume: false,
                reason: "Weekly window at \(Int(usage.sevenDay.utilization))% "
                    + "(ceiling \(Int(config.weeklyCeiling))%)"
            )
        }

        // Weekly pacing: hold if the week is being consumed faster than time
        // is passing, with a safety margin protecting the next workdays.
        let weekUsed = usage.sevenDay.utilization
        let daysLeft = daysUntilWeeklyReset(usage, now: now)
        let elapsedPct = (1.0 - min(daysLeft, 7.0) / 7.0) * 100.0
        let allowed = elapsedPct + config.pacingMargin
        if weekUsed > allowed {
            return Decision(
                resume: false,
                reason: "Weekly burn too fast: \(Int(weekUsed))% used, "
                    + String(format: "%.1f", daysLeft) + " days to reset"
            )
        }

        return Decision(
            resume: true,
            reason: "Wiggle room: \(Int(weekUsed))% of week used, "
                + String(format: "%.1f", daysLeft) + " days to reset"
        )
    }
}
