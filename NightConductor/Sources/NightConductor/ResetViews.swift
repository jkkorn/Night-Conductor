import SwiftUI

/// "Resets": when each week comes back, soonest first, and what we can
/// honestly say about free resets for each account. The reset is the moment
/// that matters on a weekly plan, so it gets its own card instead of a
/// caption buried under a bar.
struct ResetsCard: View {
    let providers: [ProviderUsage]
    var now = Date()

    private var ordered: [ProviderUsage] {
        providers.sorted {
            ($0.weekly.resetsAt ?? .distantFuture) < ($1.weekly.resetsAt ?? .distantFuture)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.m) {
            Text("Resets").font(.headline)
            VStack(alignment: .leading, spacing: Design.m) {
                ForEach(ordered) { usage in
                    ResetRow(usage: usage, now: now)
                }
            }
            .glassCard()
        }
    }
}

private struct ResetRow: View {
    let usage: ProviderUsage
    let now: Date

    /// Claude nearly out with real time left: the moment a free reset would
    /// matter, so the honest note gets the warm color and the link.
    private var nudge: Bool { UsageSummary.suggestsFreeReset(usage, now: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Design.m) {
                ProviderIcon(provider: usage.provider, size: 18)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(usage.provider.displayName).font(.body).bold()
                Spacer(minLength: Design.s)
                Text(whenText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: Design.s) {
                Image(systemName: usage.freeResetsAvailable > 0 ? "gift.fill" : "gift")
                    .font(.caption)
                    .foregroundStyle(usage.freeResetsAvailable > 0 ? Color.green : .secondary)
                    .accessibilityHidden(true)
                Text(ResetWatch.freeResetNote(provider: usage.provider, available: usage.freeResetsAvailable))
                    .font(.caption)
                    .foregroundStyle(nudge ? Color.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 26)
            if usage.provider == .claude {
                Link(destination: UsageSummary.claudeUsagePage) {
                    Label("Check in Claude", systemImage: "arrow.up.forward.app")
                        .font(.caption)
                }
                .padding(.leading, 26)
                .help("Opens your usage page on claude.ai. Night Conductor never redeems a reset for you.")
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Friday 01:59 · in 14h", or why there's no time to show.
    private var whenText: String {
        if usage.isResetSinceReading { return "Reset since last reading" }
        guard let resets = usage.weekly.resetsAt else { return "Not reported" }
        let day = resets.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "\(day) · \(ResetWatch.countdown(to: resets, now: now))"
    }
}
