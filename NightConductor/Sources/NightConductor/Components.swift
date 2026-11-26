import SwiftUI

extension View {
    /// A frosted card surface. We deliberately fake the glass with layered
    /// translucent fills + a hairline top-lit stroke instead of a real
    /// backdrop material: backdrop blur needs a live compositor (it renders
    /// opaque in offscreen snapshots and is unreliable inside a menu-bar
    /// popover), whereas this reads identically everywhere and stays crisp.
    func glassCard(cornerRadius: CGFloat = Design.cardRadius, tint: Color? = nil) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, tint: tint))
    }

    /// A subtle lift + glow on hover, the macOS "this is alive" cue.
    func hoverLift() -> some View { modifier(HoverLift()) }
}

/// The frosted card: layered translucent fills, a top-lit sheen, a quiet
/// gradient edge (accented only when the card carries a warning) and a soft
/// drop shadow so it floats on the backdrop. Reduce Transparency swaps the
/// see-through fills for a solid surface.
private struct GlassCard: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        content
            .padding(Design.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    shape.fill(reduceTransparency ? Palette.dusk : .white.opacity(0.055))  // frost
                    if let tint { shape.fill(tint.opacity(0.07)) }   // status wash: a hint, not a flood
                    shape.fill(
                        LinearGradient(                              // top-lit sheen
                            colors: [.white.opacity(0.07), .clear],
                            startPoint: .top, endPoint: .center
                        )
                    )
                }
                .shadow(color: .black.opacity(0.30), radius: 10, y: 5)
            }
            .gradientEdge(cornerRadius: cornerRadius, accent: tint)
    }
}

private struct HoverLift: ViewModifier {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && !reduceMotion ? 1.01 : 1.0)
            .onHover { isHovering in
                withAnimation(isHovering ? Motion.hoverIn : Motion.hoverOut) { hovering = isHovering }
            }
    }
}

/// A compact ring gauge for the menu bar: a colored arc that fills with
/// usage so it reads unmistakably as a consumption meter, not a weather
/// glyph. Dims when the watch is paused.
struct UsageRing: View {
    var value: Double // 0...100
    var armed: Bool = true
    var diameter: CGFloat = 13
    var lineWidth: CGFloat = 2.6
    var tint: Color? = nil   // overrides the usage ramp (e.g. a warning color)

    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.35), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 100) / 100)
                .stroke(
                    tint ?? Color.usageStatus(value),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.snappy(duration: 0.4), value: value)
        }
        .frame(width: diameter, height: diameter)
        .opacity(armed ? 1.0 : 0.45)
    }
}

/// Custom slider — replaces AppKit `Slider` (cycle source) with a draggable
/// track + knob in the accent color, with a spring on tick changes.
struct NightSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var tint: Color = .indigo
    var label: String = "Value"
    var valueText: String? = nil

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let frac = span == 0 ? 0 : (value - range.lowerBound) / span
            let w = geo.size.width
            let knobX = max(7, min(w - 7, w * frac))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15)).frame(height: 4)
                Capsule().fill(tint.gradient).frame(width: knobX, height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: knobX - 7)
                    .animation(.snappy(duration: 0.15), value: value)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    let f = max(0, min(1, g.location.x / w))
                    let raw = range.lowerBound + f * span
                    let stepped = (raw / step).rounded() * step
                    value = min(range.upperBound, max(range.lowerBound, stepped))
                }
            )
        }
        .frame(height: 18)
        // A drag-only track is invisible to VoiceOver and the keyboard; expose
        // it as a standard adjustable control that moves one step at a time.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueText ?? "\(Int(value))")
        .accessibilityAdjustableAction { direction in
            let next = direction == .increment ? value + step : value - step
            value = min(range.upperBound, max(range.lowerBound, next))
        }
    }
}

/// The hero "Resume now" button: violet glass with light on its top half,
/// the app's one accented edge, a single light sweep when it first appears,
/// and a quick squeeze on press.
struct GlowButtonStyle: ButtonStyle {
    var disabled: Bool
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Design.cardRadius)
        let base = disabled ? AnyShapeStyle(Color.gray.opacity(0.5))
                            : AnyShapeStyle(LinearGradient(colors: [Palette.violetTop, Palette.violetBottom],
                                                           startPoint: .top, endPoint: .bottom))
        configuration.label
            .font(.body).bold()
            .frame(maxWidth: .infinity)
            .padding(.vertical, Design.m + 2)
            .background(base, in: shape)
            .overlay {   // glass: light catching the top half
                shape.fill(LinearGradient(colors: [.white.opacity(0.22), .clear],
                                          startPoint: .top, endPoint: .center))
                    .allowsHitTesting(false)
            }
            .overlay { if !disabled { SheenSweep().clipShape(shape) } }
            .foregroundStyle(.white)
            .gradientEdge(accent: disabled ? nil : .white)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .shadow(color: Palette.violetBottom.opacity(disabled ? 0 : 0.5),
                    radius: configuration.isPressed ? 5 : 12, y: 4)
            .animation(Motion.press, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}
