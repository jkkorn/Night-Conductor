import SwiftUI

/// The single entrance pattern: when the popover opens, cards rise 6pt and
/// fade in, lightly staggered top to bottom so the eye reads them in order.
struct RevealOnAppear: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isStillRender) private var isStillRender
    @State private var shown = false

    func body(content: Content) -> some View {
        let visible = shown || isStillRender
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 6)
            .onAppear(perform: reveal)
    }

    private func reveal() {
        withAnimation(Motion.entrance(index: index, reduceMotion: reduceMotion)) { shown = true }
    }
}

extension View {
    func revealOnAppear(index: Int) -> some View { modifier(RevealOnAppear(index: index)) }
}
