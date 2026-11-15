import Foundation

/// An AI subscription whose weekly allowance Night Conductor can read.
enum ProviderID: String, Codable, CaseIterable, Sendable {
    case claude
    case chatgpt
    case grok

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        case .grok: return "Grok"
        }
    }

    /// SF Symbol shown beside the meter. Generic on purpose: we don't ship
    /// other companies' logos.
    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .chatgpt: return "circle.hexagongrid.fill"
        case .grok: return "bolt.fill"
        }
    }
}

/// One provider's weekly allowance, in a single shape whatever the source
/// (an HTTPS endpoint, a Codex log line, a Grok Bot cache file), so the
/// forecast and alert logic never needs to know where a number came from.
struct ProviderUsage: Equatable, Identifiable, Sendable {
    static let week: TimeInterval = 7 * 86_400

    let provider: ProviderID
    let source: String          // where it was read: "Claude Code", "Codex", "Grok Bot"
    let plan: String?
    let weekly: UsageWindow
    var windowLength: TimeInterval = ProviderUsage.week
    let readAt: Date            // when the SOURCE took this reading
    var explicitStart: Date? = nil
    /// The reading predates a reset we've since passed (see `normalized`).
    var isResetSinceReading = false

    var id: ProviderID { provider }

    var windowStart: Date? {
        explicitStart ?? weekly.resetsAt?.addingTimeInterval(-windowLength)
    }

    /// Local caches (Codex, Grok Bot) only update when you use that app, so a
    /// reading can be from a window that has since reset. Show it as fresh-
    /// window 0% rather than a stale "80% used" that's no longer true.
    func normalized(now: Date) -> ProviderUsage {
        guard let resets = weekly.resetsAt, resets <= now else { return self }
        var copy = ProviderUsage(provider: provider, source: source, plan: plan,
                                 weekly: UsageWindow(utilization: 0, resetsAt: nil),
                                 windowLength: windowLength, readAt: readAt)
        copy.isResetSinceReading = true
        return copy
    }

    static func claude(from snapshot: UsageSnapshot) -> ProviderUsage {
        ProviderUsage(provider: .claude, source: "Claude Code", plan: snapshot.plan,
                      weekly: snapshot.sevenDay, readAt: snapshot.fetchedAt,
                      explicitStart: snapshot.weeklyStartedAt)
    }
}
