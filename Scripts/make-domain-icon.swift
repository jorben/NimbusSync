#!/usr/bin/env swift
// Regenerates the Domain icon from Cloudreve's logo.
//
//   Design/CloudreveLogo.svg  ->  Packages/NimbusSyncDesignSystem/Sources/Resources/CloudreveLogo{,@2x,@3x}.png
//
// Run from the repository root:  swift Scripts/make-domain-icon.swift
//
// The app still supports macOS 13, whose NSImage cannot draw SVG, so the logo ships as bitmaps.
// The host running this script must be macOS 14 or later.

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Design/CloudreveLogo.svg")
let output = root.appendingPathComponent("Packages/NimbusSyncDesignSystem/Sources/Resources")

/// The largest Domain icon drawn is 40 pt; 48 pt leaves headroom without bloating the bundle.
let points = 48

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard let logo = NSImage(contentsOf: source) else { fail("cannot read \(source.path)") }

for scale in 1...3 {
    let pixels = points * scale
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fail("cannot allocate a \(pixels) px bitmap") }
    bitmap.size = NSSize(width: points, height: points)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    logo.draw(in: NSRect(x: 0, y: 0, width: points, height: points))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fail("cannot encode PNG") }
    let name = scale == 1 ? "CloudreveLogo.png" : "CloudreveLogo@\(scale)x.png"
    do {
        try png.write(to: output.appendingPathComponent(name))
    } catch {
        fail("cannot write \(name): \(error)")
    }
    print("wrote \(name) (\(pixels) px)")
}
