import SwiftUI

/// A usage bar with a soft glow in its own color, so a provider's budget
/// reads at a glance. It fills from empty when it first appears (the one
/// moment worth animating), and snaps straight to its value under Reduce
/// Motion or in an offscreen still.
struct GlowBar: View {
    let value: Double
    var tint: Color = .accentColor
    var height: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isStillRender) private var isStillRender
    @State private var appeared = false

    private var fraction: Double {
        let shown = (appeared || reduceMotion || isStillRender) ? value : 0
        return min(max(shown, 0), 100) / 100
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.75), tint],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(alignment: .top) {   // light catching the top edge
                        Capsule().fill(.white.opacity(0.25)).frame(height: max(1, height / 3))
                            .padding(.horizontal, height / 2)
                    }
                    .frame(width: max(height, geo.size.width * fraction))
                    .shadow(color: tint.opacity(0.55), radius: height * 0.8)
            }
            .animation(reduceMotion ? nil : Motion.fill, value: fraction)
        }
        .frame(height: height)
        .onAppear { appeared = true }
        .accessibilityHidden(true)
    }
}
