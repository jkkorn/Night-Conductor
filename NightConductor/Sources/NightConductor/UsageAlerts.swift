import Foundation
import UserNotifications

struct AlertSettings: Equatable {
    var burnHot: Bool
    var runOut: Bool
    var sensitivity: BurnSensitivity = .balanced
    /// "Claude's week reset": the good-news alert. On by default.
    var weekReset: Bool = true

    static let burnHotKey = "alertBurnHot"
    static let weekResetKey = "alertWeekReset"
    static let runOutKey = "alertRunOut"
    static let sensitivityKey = "alertBurnSensitivity"

    static func fromDefaults(_ d: UserDefaults = .standard) -> AlertSettings {
        AlertSettings(burnHot: d.object(forKey: burnHotKey) == nil || d.bool(forKey: burnHotKey),
                      runOut: d.object(forKey: runOutKey) == nil || d.bool(forKey: runOutKey),
                      sensitivity: d.string(forKey: sensitivityKey).flatMap(BurnSensitivity.init) ?? .balanced,
                      weekReset: d.object(forKey: weekResetKey) == nil || d.bool(forKey: weekResetKey))
    }
}

struct UsageAlert: Equatable {
    enum Kind: String { case burningHot, runOutBeforeReset }

    let provider: ProviderID
    let kind: Kind
    let title: String
    let body: String
    /// Once-per-window for run-out; per-provider (with cooldown) for hot.
    let dedupeKey: String
}

/// Decides which budget alerts to raise and makes sure each one is said once.
enum UsageAlerts {
    static let hotCooldown: TimeInterval = 3 * 3600
    static let sentKey = "usageAlertsSent"

    static func candidates(usage: ProviderUsage, assessment: BurnAssessment,
                           settings: AlertSettings, now: Date) -> [UsageAlert] {
        // A reading from a window that already reset says nothing about now.
        guard let resets = usage.weekly.resetsAt, resets > now,
              // nor does one too old to say anything about today
              now.timeIntervalSince(usage.readAt) <= UsageSummary.staleAfter else { return [] }
        let name = usage.provider.displayName
        let used = Int(usage.weekly.utilization.rounded())
        var alerts: [UsageAlert] = []

        if settings.burnHot, assessment.isBurningHot, let recent = assessment.recentRate {
            let multiple = assessment.usualRate.map { usual in
                usual > 0 ? ", about \(Int((recent / usual).rounded()))x your usual pace" : ""
            } ?? ""
            alerts.append(UsageAlert(
                provider: usage.provider, kind: .burningHot,
                title: "\(name): burning faster than usual",
                body: "You used about \(Int(recent.rounded()))% of your weekly \(name) budget in the last hour"
                    + "\(multiple). \(used)% used, resets \(stamp(resets)).",
                dedupeKey: "hot.\(usage.provider.rawValue)"
            ))
        }

        if settings.runOut, let runOut = assessment.runsOutAt {
            alerts.append(UsageAlert(
                provider: usage.provider, kind: .runOutBeforeReset,
                title: "\(name): on track to run out before reset",
                body: "At this pace you\u{2019}ll \(PaceStatus.runOutPhrase(runOut, resets: resets)). "
                    + "\(used)% used so far.",
                dedupeKey: "runout.\(usage.provider.rawValue).\(Int(resets.timeIntervalSince1970 / 3600))"
            ))
        }
        return alerts
    }

    static func unsent(_ alerts: [UsageAlert], sent: [String: Date], now: Date) -> [UsageAlert] {
        alerts.filter { alert in
            guard let last = sent[alert.dedupeKey] else { return true }
            return alert.kind == .burningHot && now.timeIntervalSince(last) >= hotCooldown
        }
    }

    /// The sent log with these alerts recorded, pruned of entries older than a week.
    static func marking(_ alerts: [UsageAlert], sent: [String: Date], now: Date) -> [String: Date] {
        var updated = sent.filter { now.timeIntervalSince($0.value) < 8 * 86_400 }
        for alert in alerts { updated[alert.dedupeKey] = now }
        return updated
    }

    // MARK: delivery

    static func loadSent(_ d: UserDefaults = .standard) -> [String: Date] {
        (d.dictionary(forKey: sentKey) as? [String: Double] ?? [:])
            .mapValues { Date(timeIntervalSince1970: $0) }
    }

    static func saveSent(_ sent: [String: Date], _ d: UserDefaults = .standard) {
        d.set(sent.mapValues(\.timeIntervalSince1970), forKey: sentKey)
    }

    static func post(_ alert: UsageAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        content.threadIdentifier = "night-conductor.budget"
        let request = UNNotificationRequest(identifier: "night-conductor.\(alert.dedupeKey)",
                                            content: content, trigger: nil)
        // Ask for permission in context, the first time an alert is actually
        // due, never as an unprompted launch dialog.
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { center.add(request) }
                }
            case .denied:
                return
            default:
                center.add(request)
            }
        }
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

}
