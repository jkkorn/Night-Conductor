// Renders the Night Conductor app icon: moon + stars on a night gradient.
// Usage: swift make-icon.swift /path/to/output.png
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS-style rounded square with the standard margin
let inset = size * 0.09
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let radius = rect.width * 0.2237
NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.10, green: 0.08, blue: 0.28, alpha: 1),
    NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.12, alpha: 1),
])!
gradient.draw(in: rect, angle: -90)

// Crescent moon: fill the full disc, then "punch" the bite by re-drawing
// the background gradient clipped to an offset circle — the punched area
// becomes exact background again.
let moonRadius = rect.width * 0.30
let moonCenter = NSPoint(x: rect.midX - rect.width * 0.05, y: rect.midY)
NSColor(calibratedRed: 0.96, green: 0.93, blue: 0.82, alpha: 1).setFill()
NSBezierPath(
    ovalIn: NSRect(
        x: moonCenter.x - moonRadius, y: moonCenter.y - moonRadius,
        width: moonRadius * 2, height: moonRadius * 2
    )
).fill()

NSGraphicsContext.current?.saveGraphicsState()
let punchOffset = moonRadius * 0.62
NSBezierPath(
    ovalIn: NSRect(
        x: moonCenter.x - moonRadius + punchOffset,
        y: moonCenter.y - moonRadius + punchOffset * 0.40,
        width: moonRadius * 2, height: moonRadius * 2
    )
).addClip()
gradient.draw(in: rect, angle: -90)
NSGraphicsContext.current?.restoreGraphicsState()

// A few stars
let stars: [(CGFloat, CGFloat, CGFloat)] = [
    (0.68, 0.72, 0.022), (0.76, 0.58, 0.013), (0.62, 0.34, 0.016),
    (0.30, 0.78, 0.012), (0.74, 0.80, 0.010), (0.36, 0.26, 0.011),
]
NSColor.white.withAlphaComponent(0.9).setFill()
for (fx, fy, fr) in stars {
    let r = size * fr
    let center = NSPoint(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * fy)
    NSBezierPath(
        ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    ).fill()
}

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write("Failed to render icon\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath)")
