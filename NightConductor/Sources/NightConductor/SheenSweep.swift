import SwiftUI

/// A single soft band of light that crosses a surface once when it appears,
/// the "this is the thing to press" cue. It never loops, never runs under
/// Reduce Motion, and is absent from offscreen stills.
struct SheenSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isStillRender) private var isStillRender
    @State private var progress: CGFloat = -0.4

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, .white.opacity(0.28), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.35)
                .rotationEffect(.degrees(18))
                .offset(x: geo.size.width * progress)
        }
        .opacity(reduceMotion || isStillRender ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear(perform: sweep)
    }

    private func sweep() {
        guard !reduceMotion, !isStillRender else { return }
        withAnimation(.easeInOut(duration: 0.9).delay(0.35)) { progress = 1.2 }
    }
}
