// Renders the AstroTool app icon: a 1024x1024 PNG with CoreGraphics (no UI),
// a night-sky gradient, a deterministic star field, and a folder silhouette
// holding a bright four-point star (the tool manages an astro-photo
// library). Then converts it to a .icns via `sips` + `iconutil`.
//
// Usage: swift icon/make_icon.swift
// Writes: icon/AppIcon_1024.png, icon/AppIcon.icns
// Idempotent: safe to re-run, always overwrites both outputs deterministically.

import AppKit

let iconDir = URL(fileURLWithPath: #file).deletingLastPathComponent()
let pngPath = iconDir.appendingPathComponent("AppIcon_1024.png")
let icnsPath = iconDir.appendingPathComponent("AppIcon.icns")
let size: CGFloat = 1024
let pixelSize = Int(size)

// Draw into an explicit bitmap context at exactly 1024x1024 pixels --
// NSImage.lockFocus() would pick up the screen's Retina backing scale (2x)
// and silently double the output to 2048x2048, which is wrong for an
// iconset source image.
guard let ctx = CGContext(
    data: nil,
    width: pixelSize,
    height: pixelSize,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

func color(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a).cgColor
}

// Rounded-rect clip (macOS icon corner ~= 22.37% of the side), with the usual
// small margin so the glyph doesn't touch the edge of the canvas.
let margin = size * 0.02
let rect = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
let radius = rect.width * 0.2237
ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()

// Night-sky vertical gradient: near-black at the top, deep navy toward the
// bottom (a subtle horizon glow).
let sky = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(6, 8, 20), color(13, 20, 46), color(24, 38, 74)] as CFArray,
    locations: [0.0, 0.6, 1.0]
)!
ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// Deterministic star field: fixed positions/radii/brightness (a small
// hand-picked LCG-style sequence, NOT Swift's random), so re-running the
// script always produces the same PNG bytes for the star layer.
struct StarSeed { let x: Double; let y: Double; let r: Double; let bright: Double }
func lcgSeq(_ seed: UInt64, count: Int) -> [Double] {
    var state = seed
    var out: [Double] = []
    for _ in 0..<count {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        out.append(Double((state >> 33) & 0xFFFF_FFFF) / Double(0xFFFF_FFFF))
    }
    return out
}
let starCount = 34
let rawX = lcgSeq(88172645463325252, count: starCount)
let rawY = lcgSeq(519529651692762524, count: starCount)
let rawR = lcgSeq(998244353123456789, count: starCount)
let rawB = lcgSeq(123456789987654321, count: starCount)
var stars: [StarSeed] = []
for i in 0..<starCount {
    stars.append(StarSeed(
        x: 0.06 + rawX[i] * 0.88,
        y: 0.10 + rawY[i] * 0.86,
        r: 2.2 + rawR[i] * 5.5,
        bright: 0.45 + rawB[i] * 0.55
    ))
}
for star in stars {
    let cx = star.x * size
    let cy = star.y * size
    let r = star.r * (size / 1024)
    // Alternate white / blue-white tint for variety.
    let tint = star.bright > 0.75 ? color(255, 255, 255, star.bright) : color(197, 218, 255, star.bright)
    ctx.setFillColor(tint)
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()
    // Faint sparkle cross on the brighter stars.
    if star.bright > 0.85 {
        ctx.setStrokeColor(tint)
        ctx.setLineWidth(r * 0.35)
        ctx.setLineCap(.round)
        let spike = r * 2.4
        ctx.move(to: CGPoint(x: cx - spike, y: cy)); ctx.addLine(to: CGPoint(x: cx + spike, y: cy))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: cx, y: cy - spike)); ctx.addLine(to: CGPoint(x: cx, y: cy + spike))
        ctx.strokePath()
    }
}

// Folder silhouette (library motif), lower half of the canvas.
let folderColor = color(64, 82, 130)
let folderWidth = size * 0.62
let folderHeight = size * 0.40
let folderX = (size - folderWidth) / 2
let folderY = size * 0.14
let tabWidth = folderWidth * 0.42
let tabHeight = size * 0.045
let cornerR = size * 0.03

let folderPath = CGMutablePath()
// Tab (top-left notch of the folder).
folderPath.move(to: CGPoint(x: folderX + cornerR, y: folderY + folderHeight + tabHeight))
folderPath.addLine(to: CGPoint(x: folderX + tabWidth, y: folderY + folderHeight + tabHeight))
folderPath.addLine(to: CGPoint(x: folderX + tabWidth + tabHeight, y: folderY + folderHeight))
// Body, rounded corners.
folderPath.addArc(tangent1End: CGPoint(x: folderX + folderWidth, y: folderY + folderHeight),
                   tangent2End: CGPoint(x: folderX + folderWidth, y: folderY + folderHeight - cornerR),
                   radius: cornerR)
folderPath.addArc(tangent1End: CGPoint(x: folderX + folderWidth, y: folderY),
                   tangent2End: CGPoint(x: folderX + folderWidth - cornerR, y: folderY),
                   radius: cornerR)
folderPath.addArc(tangent1End: CGPoint(x: folderX, y: folderY),
                   tangent2End: CGPoint(x: folderX, y: folderY + cornerR),
                   radius: cornerR)
folderPath.addArc(tangent1End: CGPoint(x: folderX, y: folderY + folderHeight),
                   tangent2End: CGPoint(x: folderX + cornerR, y: folderY + folderHeight),
                   radius: cornerR)
folderPath.closeSubpath()

ctx.setFillColor(folderColor)
ctx.addPath(folderPath)
ctx.fillPath()

// Prominent four-point star "badge" centered over the folder, evoking a
// telescope target / bright star.
func starPoint(center: CGPoint, angle: CGFloat, radius: CGFloat) -> CGPoint {
    CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
}
let badgeCenter = CGPoint(x: size / 2, y: folderY + folderHeight * 0.62)
let outerR = size * 0.155
let innerR = outerR * 0.38
let starGlyph = CGMutablePath()
let points = 4
for i in 0..<(points * 2) {
    let angle = CGFloat(i) / CGFloat(points * 2) * .pi * 2 - .pi / 2
    let radius = i % 2 == 0 ? outerR : innerR
    let pt = starPoint(center: badgeCenter, angle: angle, radius: radius)
    if i == 0 { starGlyph.move(to: pt) } else { starGlyph.addLine(to: pt) }
}
starGlyph.closeSubpath()

// Soft glow behind the star.
let glow = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(255, 255, 255, 0.55), color(255, 255, 255, 0)] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawRadialGradient(glow, startCenter: badgeCenter, startRadius: 0,
                        endCenter: badgeCenter, endRadius: outerR * 1.9, options: [])

ctx.setFillColor(NSColor.white.cgColor)
ctx.addPath(starGlyph)
ctx.fillPath()

// Two small companion sparkles near the badge for a constellation feel.
for (dx, dy, r) in [(-outerR * 1.5, outerR * 0.9, size * 0.012), (outerR * 1.6, -outerR * 0.3, size * 0.009)] {
    let pt = CGPoint(x: badgeCenter.x + dx, y: badgeCenter.y + dy)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addArc(center: pt, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()
}

guard let cgImage = ctx.makeImage() else { exit(2) }
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(2) }
try? png.write(to: pngPath)
print("wrote \(pngPath.path)")

// --- Convert to .icns via sips + iconutil (standard iconset sizes). ---

let iconset = iconDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func run(_ launchPath: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

let specs: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for spec in specs {
    let dest = iconset.appendingPathComponent("\(spec.name).png")
    run("/usr/bin/sips", ["-z", "\(spec.px)", "\(spec.px)", pngPath.path, "--out", dest.path])
}
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icnsPath.path])
try? FileManager.default.removeItem(at: iconset)

if FileManager.default.fileExists(atPath: icnsPath.path) {
    print("wrote \(icnsPath.path)")
} else {
    FileHandle.standardError.write("warning: iconutil did not produce \(icnsPath.path)\n".data(using: .utf8)!)
}
