import Foundation

/// One resumed session, kept so we can show "what happened last night" and a
/// shareable weekly stat. Persisted in UserDefaults, pruned to 30 days.
struct ResumeEvent: Codable, Equatable {
    let date: Date
    let title: String
    let kind: String // "usage_limit" | "transient"
    let inConductor: Bool
}

enum ResumeHistory {
    private static let key = "resumeHistory"
    private static let maxAge: TimeInterval = 30 * 86_400

    static func record(_ event: ResumeEvent, defaults: UserDefaults = .standard) {
        var events = load(defaults: defaults)
        events.append(event)
        let cutoff = event.date.addingTimeInterval(-maxAge)
        events = events.filter { $0.date >= cutoff }
        if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: key)
        }
    }

    static func load(defaults: UserDefaults = .standard) -> [ResumeEvent] {
        guard let data = defaults.data(forKey: key),
              let events = try? JSONDecoder().decode([ResumeEvent].self, from: data)
        else { return [] }
        return events
    }

    static func count(within interval: TimeInterval, now: Date = Date(),
                      defaults: UserDefaults = .standard) -> Int {
        let cutoff = now.addingTimeInterval(-interval)
        return load(defaults: defaults).filter { $0.date >= cutoff }.count
    }

    static func weekCount(now: Date = Date(), defaults: UserDefaults = .standard) -> Int {
        count(within: 7 * 86_400, now: now, defaults: defaults)
    }
}
