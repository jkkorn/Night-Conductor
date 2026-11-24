import SwiftUI

/// A quiet gradient edge for premium surfaces: a light highlight at the top
/// left, one accent through the middle, fading out at the bottom right (135°).
/// It frames the content, it doesn't compete with it. Plain cards get a
/// neutral edge; only one level at a time (the urgent card, the hovered row,
/// the primary button) gets a colored accent.
///
/// With Increase Contrast on, the edge is drawn stronger so card boundaries
/// stay visible.
struct GradientEdge: ViewModifier {
    var cornerRadius: CGFloat = Design.cardRadius
    var accent: Color? = nil
    var lineWidth: CGFloat = 1
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let boost = contrast == .increased ? 1.8 : 1.0
        let middle = accent?.opacity(0.36 * boost) ?? .white.opacity(0.12 * boost)
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.30 * boost), middle, .white.opacity(0.06 * boost)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: lineWidth
                )
                .allowsHitTesting(false)
        }
    }
}

extension View {
    func gradientEdge(cornerRadius: CGFloat = Design.cardRadius, accent: Color? = nil,
                      lineWidth: CGFloat = 1) -> some View {
        modifier(GradientEdge(cornerRadius: cornerRadius, accent: accent, lineWidth: lineWidth))
    }
}
