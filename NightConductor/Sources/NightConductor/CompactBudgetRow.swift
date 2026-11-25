import SwiftUI

/// One line for an account that's fine: icon, name, plan, a bold "29% used"
/// and its glowing bar. Click to open the full card. Hover brightens it
/// quickly and settles back slower, the standard "this is alive" cue.
struct CompactBudgetRow: View {
    let usage: ProviderUsage
    let onOpen: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: Design.m) {
                HStack(spacing: Design.m) {
                    ProviderIcon(provider: usage.provider, size: 22)
                    Text(usage.provider.displayName).font(.body).bold()
                    if let plan = usage.plan {
                        Text(plan).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if usage.freeResetsAvailable > 0 {
                        Label("\(usage.freeResetsAvailable)", systemImage: "gift")
                            .font(.callout).foregroundStyle(.secondary)
                            .help(UsageWording.freeResets(usage.freeResetsAvailable))
                            .accessibilityLabel(UsageWording.freeResets(usage.freeResetsAvailable))
                    }
                    Spacer(minLength: Design.s)
                    UsedFigure(percent: usage.weekly.utilization, font: .title3)
                    Image(systemName: "chevron.right")
                        .font(.caption).bold().foregroundStyle(.tertiary)
                        .offset(x: hovering && !reduceMotion ? 2 : 0)
                }
                GlowBar(value: usage.weekly.utilization, tint: ProviderBrand.accent(usage.provider), height: 5)
            }
            .padding(.horizontal, Design.l).padding(.vertical, Design.m + 2)
            .background(.white.opacity(hovering ? 0.09 : 0.05), in: .rect(cornerRadius: Design.cardRadius))
            // Hover lights the edge in the provider's own color.
            .gradientEdge(accent: hovering ? ProviderBrand.accent(usage.provider) : nil)
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            .scaleEffect(hovering && !reduceMotion ? 1.01 : 1)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .onHover(perform: setHover)
        .accessibilityLabel("\(usage.provider.displayName): \(UsageWording.used(usage.weekly.utilization)) this week, on track")
        .accessibilityHint("Shows details")
    }

    private func setHover(_ isHovering: Bool) {
        withAnimation(isHovering ? Motion.hoverIn : Motion.hoverOut) { hovering = isHovering }
    }
}

/// "29% used": the number carries the weight, the word stays in the
/// app's one wording. Rolls digit by digit when the value changes.
struct UsedFigure: View {
    let percent: Double
    var font: Font = .title3

    var body: some View {
        Text("\(Text("\(Int(percent.rounded()))%").font(font.monospacedDigit()).bold().fontDesign(.rounded)) \(Text("used").font(.callout).foregroundStyle(.secondary))")
            .contentTransition(.numericText(value: percent))
            .animation(Motion.fill, value: percent)
    }
}

/// Press feedback for card-like buttons: a quick, slight squeeze, no bounce.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}
