import SwiftUI

/// The one-line read across every account, as a status banner: a seal when
/// everything's on track, a warning in the worst account's color otherwise.
/// Icon + words, never color alone.
struct UsageSummaryBanner: View {
    let rows: [UsageSummary.Row]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false

    private var worst: PaceStatus? {
        rows.map { PaceStatus.of($0.usage, $0.assessment) }
            .max { UsageSummary.urgency($0) < UsageSummary.urgency($1) }
    }

    /// Something worth knowing that isn't a warning (an out-of-date reading).
    private var hasNotice: Bool {
        rows.contains { PaceStatus.of($0.usage, $0.assessment).isInformational }
    }

    private var tint: Color {
        if let worst, UsageSummary.urgency(worst) >= 2 { return worst.warningTint ?? .orange }
        return hasNotice ? .gray : .green
    }

    private var symbol: String {
        if let worst, UsageSummary.urgency(worst) >= 2 { return worst.symbol }
        return hasNotice ? "clock.badge.questionmark" : "checkmark.seal.fill"
    }

    var body: some View {
        Label {
            Text(UsageSummary.headline(rows))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                // One bounce as the popover opens: the eye lands here first.
                .symbolEffect(.bounce, options: .nonRepeating, value: arrived)
        }
        .padding(.horizontal, Design.l).padding(.vertical, Design.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: Design.cardRadius))
        .gradientEdge(accent: tint)
        .animation(.smooth(duration: Motion.standard), value: tint)
        .onAppear { if !reduceMotion { arrived = true } }
    }
}
