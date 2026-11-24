import SwiftUI

/// The room the popover lives in: deep night blue at the top, where the
/// header's sky spills a soft indigo glow, settling to near-black below so
/// the cards float on it. Static on purpose: the header's stars are the one
/// living thing up there.
///
/// With Reduce Transparency on, it becomes one solid color.
struct PopoverBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Palette.night
        } else {
            ZStack {
                LinearGradient(colors: [Palette.dusk, Palette.night],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color.indigo.opacity(0.28), .clear],
                               center: .top, startRadius: 0, endRadius: 260)
            }
        }
    }
}

/// The app's few brand colors, in one place.
enum Palette {
    static let night = Color(red: 0.07, green: 0.07, blue: 0.10)
    static let dusk = Color(red: 0.10, green: 0.10, blue: 0.17)
    static let violetTop = Color(red: 0.47, green: 0.42, blue: 1.00)
    static let violetBottom = Color(red: 0.36, green: 0.30, blue: 0.92)
}
