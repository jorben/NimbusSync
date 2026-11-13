#!/usr/bin/env swift
// Draws the Dev build's app icon: the shipping artwork with a "DEV" badge in its top-right corner.
//
//   Design/AppIcon-Light.png, Design/AppIcon-Dark.png
//     -> Apps/NimbusSync/AppIconDev.icon/Assets/AppIconDev-{Light,Dark}.png
//
// Run from the repository root (Scripts/make-app-icon.sh runs it too):
//   swift Scripts/make-dev-app-icon.swift
//
// The badge is baked into the artwork rather than drawn at run time, so the Dock, Finder, Login
// Items and System Settings all show it, running or not. The artwork is full bleed and macOS masks
// it to its rounded shape, so the badge sits inside the corner radius instead of on the edge.

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Apps/NimbusSync/AppIconDev.icon/Assets")
let side = 1024

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// The badge, in the artwork's 1024 px space with the origin at the bottom left. Its right end
/// stays well inside the mask's top-right corner (radius about 230 px on a 1024 px icon).
let badge = CGRect(x: 548, y: 1024 - 96 - 168, width: 392, height: 168)
/// Turned clockwise about its centre like a sticker slapped on the corner: the right end dips
/// toward the corner, the left end lifts, and every edge stays inside the mask.
let badgeTilt: CGFloat = 14

func drawBadge(dark: Bool) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let tilt = NSAffineTransform()
    tilt.translateX(by: badge.midX, yBy: badge.midY)
    tilt.rotate(byDegrees: -badgeTilt)  // AppKit's y axis points up, so negative is clockwise.
    tilt.translateX(by: -badge.midX, yBy: -badge.midY)
    tilt.concat()

    let shape = NSBezierPath(roundedRect: badge, xRadius: badge.height / 2, yRadius: badge.height / 2)

    // A soft drop shadow lifts the badge off the artwork.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.28)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    NSColor(srgbRed: 1, green: 0.42, blue: 0.1, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Warm orange gradient, the usual colour of a pre-release mark, distinct from the brand blue.
    NSGradient(
        starting: NSColor(srgbRed: 1, green: 0.55, blue: 0.16, alpha: 1),
        ending: NSColor(srgbRed: 0.94, green: 0.27, blue: 0.1, alpha: 1)
    )?.draw(in: shape, angle: -90)

    // A white rim keeps it readable over both the light and the dark artwork.
    let rim = NSBezierPath(roundedRect: badge.insetBy(dx: 5, dy: 5), xRadius: (badge.height - 10) / 2, yRadius: (badge.height - 10) / 2)
    rim.lineWidth = 10
    NSColor.white.withAlphaComponent(dark ? 0.85 : 1).setStroke()
    rim.stroke()

    let font = NSFont.systemFont(ofSize: 104, weight: .heavy)
    let text = NSAttributedString(string: "DEV", attributes: [
        .font: font,
        .foregroundColor: NSColor.white,
        .kern: 6,
    ])
    let size = text.size()
    // Centre on the cap height, not the line box, so the letters sit in the middle of the pill.
    let origin = CGPoint(
        x: badge.midX - size.width / 2 + 3,
        y: badge.midY - font.capHeight / 2 + font.descender
    )
    text.draw(at: origin)
}

try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (appearance, dark) in [("Light", false), ("Dark", true)] {
    let source = root.appendingPathComponent("Design/AppIcon-\(appearance).png")
    guard let artwork = NSImage(contentsOf: source) else { fail("cannot read \(source.path)") }
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fail("cannot allocate a \(side) px bitmap") }
    bitmap.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    artwork.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    drawBadge(dark: dark)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fail("cannot encode PNG") }
    let name = "AppIconDev-\(appearance).png"
    do {
        try png.write(to: output.appendingPathComponent(name))
    } catch {
        fail("cannot write \(name): \(error)")
    }
    print("wrote \(output.lastPathComponent)/\(name)")
}
