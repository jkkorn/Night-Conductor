import Foundation

/// Everything about resets, kept pure (no clocks, no I/O) so each rule is
/// testable: when to hold the Mac awake, how to notice a week reset, the
/// firmware wake for a reset, and what we can honestly say about free resets.
enum ResetWatch {
    /// How long before a known reset the Mac is kept awake, so the first
    /// check after the reset happens on time instead of whenever you next
    /// touch the Mac.
    static let awakeLead: TimeInterval = 30 * 60
    /// The firmware wake fires this long before the reset.
    static let wakeLead: TimeInterval = 5 * 60

    /// Hold the Mac awake only when it buys something: there is stalled work
    /// that would be resumed, and either it can be resumed right now or the
    /// reset that frees it is close. Otherwise let the Mac sleep: a week-long
    /// keep-awake for a reset on Friday is just a drained battery.
    static func shouldKeepAwake(armed: Bool, waiting: Int, budgetAllows: Bool,
                                nextReset: Date?, now: Date) -> Bool {
        guard armed, waiting > 0 else { return false }
        if budgetAllows { return true }
        guard let nextReset else { return false }
        // A reset already in the past means the reading is stale (a failed
        // fetch, an expired sign-in): hold briefly for the fresh reading, never
        // indefinitely on old data.
        let lead = nextReset.timeIntervalSince(now)
        return lead <= awakeLead && lead > -awakeGrace
    }

    /// After a known reset passes, how long to keep waiting for the reading
    /// that confirms it before letting the Mac sleep again.
    static let awakeGrace: TimeInterval = 20 * 60

    /// A week reset when its reset time jumps at least a day later than the
    /// one we saw before. Covers the normal case (Friday's reset passed, the
    /// next one is next Friday) and an early restart (a free reset used).
    /// Sub-second jitter in the API's timestamp is not a reset.
    static func didReset(previous: Date?, current: Date?, now: Date) -> Bool {
        guard let previous, let current, current > now else { return false }
        return current.timeIntervalSince(previous) >= 86_400
    }

    /// Whether a newly read reset time should replace the remembered one.
    static func shouldStore(current: Date, previous: Date?, now: Date) -> Bool {
        guard let previous else { return true }
        return current.timeIntervalSince(previous) > 60 || previous <= now
    }

    /// `pmset repeat` wants a weekday letter (M T W R F S U) and a time.
    struct WakeSpec: Equatable, Codable {
        let day: String
        let time: String
        var pmsetArguments: String { "wakeorpoweron \(day) \(time)" }
    }

    /// The API's reset time jitters by a second or so between readings
    /// (01:59:59.7, then 02:00:00.1), so it's rounded to the nearest five
    /// minutes first; otherwise the spec flips and settings claims your reset
    /// moved when it didn't.
    static func wakeSpec(for reset: Date, calendar: Calendar = .current) -> WakeSpec? {
        let step: TimeInterval = 5 * 60
        let rounded = Date(timeIntervalSince1970: (reset.timeIntervalSince1970 / step).rounded() * step)
        let wake = rounded.addingTimeInterval(-wakeLead)
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: wake)
        guard let weekday = c.weekday, let hour = c.hour, let minute = c.minute,
              (1...7).contains(weekday) else { return nil }
        let letters = ["U", "M", "T", "W", "R", "F", "S"] // Calendar weekday 1 = Sunday
        return WakeSpec(day: letters[weekday - 1], time: String(format: "%02d:%02d:00", hour, minute))
    }

    /// "in 40m", "in 14h", "in 2d 3h", "now".
    static func countdown(to date: Date, now: Date) -> String {
        let minutes = Int(date.timeIntervalSince(now) / 60)
        guard minutes > 0 else { return "now" }
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "in \(hours)h" }
        let days = hours / 24, rem = hours % 24
        return rem == 0 ? "in \(days)d" : "in \(days)d \(rem)h"
    }

    /// What we can truthfully say about free resets, per provider. ChatGPT
    /// reports them to its own Codex app, which we ask. Anthropic only shows
    /// Claude's to its own apps; we could pretend to be one of them, and we
    /// don't. Never redeemed for you either way: spending one is your call.
    static func freeResetNote(provider: ProviderID, available: Int) -> String {
        switch provider {
        case .chatgpt:
            if available <= 0 { return "No free resets right now." }
            return available == 1
                ? "1 free reset available. Use it in Codex when you want."
                : "\(available) free resets available. Use them in Codex when you want."
        case .claude:
            return "Anthropic doesn't share free resets with other apps, so Night Conductor can't see them."
        case .grok:
            return "Grok doesn't report free resets."
        }
    }
}
