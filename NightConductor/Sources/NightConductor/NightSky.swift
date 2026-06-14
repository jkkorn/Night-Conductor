import SwiftUI

/// A living sky that reflects the real time of day: deep indigo with bright
/// stars at midnight, warm rose at dawn, pale blue (no stars) at midday,
/// burnt-orange dusk as the stars return. It also drifts (animated mesh) and
/// twinkles, and reacts to armed state. The whole point is that it breathes
/// and changes — so it can never read as a flat, generic gradient.
struct NightSkyView: View {
    var armed: Bool
    var animated: Bool = true

    /// Screenshots force a flattering night hour; the live app uses the clock.
    static var hourOverride: Double?

    // Hand-placed stars (x, y in 0...1, radius pt, twinkle phase): a few
    // bright anchors, many faint, biased up so they clear the wordmark.
    private static let stars: [(x: CGFloat, y: CGFloat, r: CGFloat, phase: Double)] = [
        (0.86, 0.22, 1.7, 0.0), (0.74, 0.40, 1.1, 1.3), (0.92, 0.52, 0.9, 2.1),
        (0.66, 0.18, 1.3, 3.4), (0.55, 0.30, 0.8, 0.7), (0.80, 0.68, 1.0, 4.2),
        (0.45, 0.16, 0.9, 5.1), (0.34, 0.26, 1.2, 2.7), (0.62, 0.55, 0.7, 1.9),
        (0.24, 0.20, 0.8, 3.9), (0.50, 0.46, 0.6, 0.4), (0.70, 0.28, 0.7, 4.8),
        (0.16, 0.34, 1.0, 2.2), (0.40, 0.62, 0.7, 5.5), (0.88, 0.36, 0.8, 1.1),
        (0.30, 0.44, 0.6, 3.1), (0.58, 0.70, 0.8, 0.9), (0.10, 0.22, 0.7, 4.4),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animated)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let hour = Self.hourOverride ?? Self.hour(from: timeline.date)
            let sky = SkyPalette.at(hour: hour)
            ZStack {
                aurora(t: t, sky: sky)
                starfield(t: t, starLevel: sky.stars)
            }
        }
    }

    private static func hour(from date: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60.0
    }

    // MARK: - Aurora (animated mesh, time-of-day palette)

    private func aurora(t: TimeInterval, sky: SkyPalette) -> some View {
        let d = animated ? 0.018 : 0.0
        func wob(_ a: Double, _ b: Double) -> Float { Float(sin(t * a + b) * d) }
        let pts: [SIMD2<Float>] = [
            [0, 0], [0.5 + wob(0.23, 1.0), 0], [1, 0],
            [0, 0.5 + wob(0.19, 2.0)],
            [0.5 + wob(0.27, 0.0), 0.5 + wob(0.21, 3.0)],
            [1, 0.5 + wob(0.17, 4.0)],
            [0, 1], [0.5 + wob(0.25, 5.0), 1], [1, 1],
        ]
        // The accent breathes only at night (aurora shimmer); by day it's flat.
        let glow = armed ? 0.5 + 0.5 * sin(t * 0.4) : 0.0
        let accent = sky.accent.opacity(sky.stars * (0.4 + 0.4 * glow))
        let top = sky.top, mid = sky.mid, bot = sky.bottom
        let colors: [Color] = [
            top, accent, top.scaled(1.05),
            mid.scaled(0.95), mid, mid.scaled(0.9),
            bot, bot.scaled(1.12), bot.scaled(0.85),
        ]
        return MeshGradient(width: 3, height: 3, points: pts, colors: colors)
    }

    // MARK: - Starfield

    private func starfield(t: TimeInterval, starLevel: Double) -> some View {
        Canvas { ctx, size in
            guard starLevel > 0.01 else { return } // no stars in daylight
            for star in Self.stars {
                let twinkle = animated ? (0.55 + 0.45 * sin(t * 1.1 + star.phase)) : 0.8
                let brightness = starLevel * (armed ? 1.0 : 0.55) * twinkle
                let p = CGPoint(x: star.x * size.width, y: star.y * size.height)
                let rect = CGRect(x: p.x - star.r, y: p.y - star.r,
                                  width: star.r * 2, height: star.r * 2)
                ctx.fill(Circle().path(in: rect.insetBy(dx: -star.r, dy: -star.r)),
                         with: .color(.white.opacity(0.10 * brightness)))
                ctx.fill(Circle().path(in: rect),
                         with: .color(.white.opacity(0.85 * brightness)))
            }
        }
    }
}

/// The sky's color bands + star intensity for a given hour, interpolated
/// between keyframes around the 24-hour clock.
struct SkyPalette {
    let top: Color, mid: Color, bottom: Color, accent: Color, stars: Double

    private struct Stop {
        let hour: Double
        let top, mid, bot, accent: SIMD3<Double>
        let stars: Double
    }

    // Keyframes around the clock (ascending hours). RGB in 0...1.
    private static let stops: [Stop] = [
        Stop(hour: 2,  top: [0.10, 0.09, 0.26], mid: [0.15, 0.12, 0.34], bot: [0.04, 0.04, 0.12], accent: [0.10, 0.45, 0.48], stars: 1.0),
        Stop(hour: 6,  top: [0.22, 0.20, 0.40], mid: [0.46, 0.28, 0.46], bot: [0.80, 0.45, 0.34], accent: [0.95, 0.62, 0.45], stars: 0.35),
        Stop(hour: 9,  top: [0.26, 0.46, 0.72], mid: [0.44, 0.62, 0.84], bot: [0.66, 0.82, 0.94], accent: [1.00, 1.00, 1.00], stars: 0.0),
        Stop(hour: 13, top: [0.22, 0.46, 0.76], mid: [0.40, 0.63, 0.88], bot: [0.68, 0.84, 0.96], accent: [1.00, 1.00, 1.00], stars: 0.0),
        Stop(hour: 18, top: [0.14, 0.12, 0.34], mid: [0.48, 0.22, 0.44], bot: [0.82, 0.40, 0.28], accent: [0.95, 0.50, 0.34], stars: 0.45),
        Stop(hour: 21, top: [0.12, 0.10, 0.30], mid: [0.18, 0.14, 0.40], bot: [0.05, 0.05, 0.16], accent: [0.10, 0.42, 0.46], stars: 0.85),
    ]

    static func at(hour: Double) -> SkyPalette {
        let h = hour.truncatingRemainder(dividingBy: 24)
        // Build a circular bracket: shift hours so the first stop starts the day.
        var hh = h
        if hh < stops[0].hour { hh += 24 }
        for i in 0..<stops.count {
            let a = stops[i]
            let b = stops[(i + 1) % stops.count]
            let bHour = b.hour <= a.hour ? b.hour + 24 : b.hour
            if hh >= a.hour && hh <= bHour {
                let f = (hh - a.hour) / (bHour - a.hour)
                return blend(a, b, f)
            }
        }
        return blend(stops[0], stops[0], 0)
    }

    private static func blend(_ a: Stop, _ b: Stop, _ t: Double) -> SkyPalette {
        func lerp(_ x: SIMD3<Double>, _ y: SIMD3<Double>) -> Color {
            let v = x + (y - x) * t
            return Color(red: v.x, green: v.y, blue: v.z)
        }
        return SkyPalette(
            top: lerp(a.top, b.top), mid: lerp(a.mid, b.mid),
            bottom: lerp(a.bot, b.bot), accent: lerp(a.accent, b.accent),
            stars: a.stars + (b.stars - a.stars) * t
        )
    }
}

private extension Color {
    /// Multiply RGB brightness (clamped). Used to vary mesh cells subtly.
    func scaled(_ f: Double) -> Color {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return Color(
            red: min(1, ns.redComponent * f),
            green: min(1, ns.greenComponent * f),
            blue: min(1, ns.blueComponent * f)
        )
    }
}

/// The moon mark with a soft, breathing glow.
struct GlowingMoon: View {
    var armed: Bool
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: "moon.stars.fill")
            .font(.system(size: size))
            .foregroundStyle(.white.opacity(armed ? 0.9 : 0.5))
            .shadow(color: .white.opacity(armed ? 0.5 : 0.15), radius: armed ? 10 : 4)
            .shadow(color: Color(red: 0.5, green: 0.5, blue: 0.95).opacity(armed ? 0.6 : 0.2),
                    radius: armed ? 18 : 6)
    }
}
