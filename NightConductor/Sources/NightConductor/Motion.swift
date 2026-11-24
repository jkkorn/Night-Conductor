import SwiftUI

/// One motion vocabulary for the whole app, so every hover, press and
/// entrance feels like the same product. Personality: calm and premium (it's
/// a night app): no overshoot on anything that carries information, three
/// durations, one entrance pattern.
enum Motion {
    static let quick: Double = 0.12      // hover, press: must feel instant
    static let standard: Double = 0.28   // cards and icons arriving
    static let slow: Double = 0.55       // a usage bar filling to its value
    static let stagger: Double = 0.035   // between cards; total stays under 0.2s

    static let hoverIn = Animation.easeOut(duration: 0.09)
    static let hoverOut = Animation.easeOut(duration: 0.18)  // exits slower than entries
    static let press = Animation.snappy(duration: quick)
    static let fill = Animation.smooth(duration: slow)

    /// Cards rise a few points and fade in. With Reduce Motion: fade only.
    static func entrance(index: Int, reduceMotion: Bool) -> Animation {
        let base: Animation = reduceMotion ? .easeOut(duration: quick) : .smooth(duration: standard)
        return base.delay(reduceMotion ? 0 : Double(min(index, 5)) * stagger)
    }
}

extension EnvironmentValues {
    /// True while rendering an offscreen still (docs, screenshots): show every
    /// view in its final state instead of mid-entrance.
    @Entry var isStillRender = false
}
