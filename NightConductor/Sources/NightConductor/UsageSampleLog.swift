import Foundation

/// A rolling history of weekly-percent readings per provider: the memory
/// behind "more than usual". Immutable: `appending` returns a new log.
///
/// Written to Application Support (not UserDefaults, which is meant for small
/// prefs). Only numbers and dates are stored, no session titles or content.
struct UsageSampleLog: Codable, Equatable {
    static let maxAge: TimeInterval = 8 * 86_400
    static let maxPerProvider = 2_000
    /// Unchanged readings are skipped, but one is kept every 15 minutes so the
    /// "last hour" window always has a starting point.
    static let heartbeat: TimeInterval = 15 * 60

    private(set) var byProvider: [String: [UsageSample]] = [:]

    func samples(for provider: ProviderID) -> [UsageSample] {
        byProvider[provider.rawValue] ?? []
    }

    func appending(_ sample: UsageSample, for provider: ProviderID) -> UsageSampleLog {
        var list = samples(for: provider)
        if let last = list.last {
            let unchanged = last.percent == sample.percent && last.resetsAt == sample.resetsAt
            let tooSoon = sample.at.timeIntervalSince(last.at) < Self.heartbeat
            if sample.at <= last.at || (unchanged && tooSoon) { return self }
        }
        list.append(sample)
        let cutoff = sample.at.addingTimeInterval(-Self.maxAge)
        list = Array(list.filter { $0.at >= cutoff }.suffix(Self.maxPerProvider))
        var copy = self
        copy.byProvider[provider.rawValue] = list
        return copy
    }

    // MARK: persistence

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Night Conductor/usage-samples.json")
    }

    static func load(from url: URL = defaultURL) -> UsageSampleLog {
        guard let data = SafeFile.readAll(url, maxBytes: 4 * 1024 * 1024),
              let log = try? JSONDecoder().decode(UsageSampleLog.self, from: data)
        else { return UsageSampleLog() }
        return log
    }

    func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: [.atomic])
    }
}
