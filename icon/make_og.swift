// Renders the 1200×630 social preview card (Open Graph / Twitter) for the
// downloads page: the app icon on the same night-sky gradient as the app
// icon itself, with the name + tagline.
// Usage: swift icon/make_og.swift
// Reads: icon/AppIcon_1024.png
// Writes: docs/og-image.jpg

import AppKit

let iconDir = URL(fileURLWithPath: #file).deletingLastPathComponent()
let iconPath = iconDir.appendingPathComponent("AppIcon_1024.png").path
let outPath = iconDir.deletingLastPathComponent().appendingPathComponent("docs/og-image.jpg").path
let width: CGFloat = 1200, height: CGFloat = 630

func color(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

// Draw into an explicit bitmap rep at exact pixel dimensions -- NSImage's
// lockFocus() would pick up the screen's Retina backing scale (2x) and
// silently double the output to 2400x1260, which is wrong for a fixed-size
// Open Graph card.
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// Same night-sky gradient as the app icon (near-black top, deep navy bottom).
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(6, 8, 20).cgColor, color(13, 20, 46).cgColor, color(24, 38, 74).cgColor] as CFArray,
    locations: [0.0, 0.6, 1.0]
)!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 0, y: height),
                       end: CGPoint(x: 0, y: 0),
                       options: [])

// Deterministic star field scattered across the card (same taste as the app
// icon: fixed positions, not Swift's random, so re-running is byte-stable).
func lcgSeq(_ seed: UInt64, count: Int) -> [Double] {
    var state = seed
    var out: [Double] = []
    for _ in 0..<count {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        out.append(Double(state >> 33) / Double(1 << 31))
    }
    return out
}
let starXs = lcgSeq(11, count: 60)
let starYs = lcgSeq(22, count: 60)
let starRs = lcgSeq(33, count: 60)
for i in 0..<60 {
    let x = starXs[i] * width
    let y = starYs[i] * height
    let r = 0.6 + starRs[i] * 1.6
    NSColor.white.withAlphaComponent(0.25 + starRs[i] * 0.45).setFill()
    let dot = NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    dot.fill()
}

// App icon, left of the text.
let iconSize: CGFloat = 260
let iconRect = NSRect(x: 110, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
if let icon = NSImage(contentsOfFile: iconPath) {
    let radius = iconSize * 0.2237
    let path = NSBezierPath(roundedRect: iconRect, xRadius: radius, yRadius: radius)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34,
                  color: NSColor.black.withAlphaComponent(0.5).cgColor)
    NSColor.black.setFill()
    path.fill()
    ctx.restoreGState()
    ctx.saveGState()
    path.addClip()
    icon.draw(in: iconRect)
    ctx.restoreGState()
}

func draw(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
    ]
    NSAttributedString(string: text, attributes: attributes)
        .draw(at: NSPoint(x: x, y: y))
}

let textX: CGFloat = 430
draw("AstroTool", x: textX, y: 355, size: 92, weight: .bold, alpha: 1.0)
draw("Asztrofotó-könyvtár karbantartó", x: textX, y: 292, size: 34, weight: .medium, alpha: 0.95)
draw("Audit · minőség-pontozás · session-kezelés", x: textX, y: 236, size: 26, weight: .regular, alpha: 0.8)
draw("macOS · Apple Silicon", x: textX, y: 164, size: 24, weight: .semibold, alpha: 0.7)

NSGraphicsContext.restoreGraphicsState()

guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { exit(2) }
try? jpeg.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
