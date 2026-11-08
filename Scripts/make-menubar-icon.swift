#!/usr/bin/env swift
// Regenerates the menu bar template icon from its monochrome design source.
//
//   Design/MenuBarIcon.png  ->  Packages/NimbusSyncDesignSystem/Sources/Resources/MenuBarIcon{,@2x,@3x}.png
//
// Run from the repository root:  swift Scripts/make-menubar-icon.swift
//
// The status item draws the icon as a template, so the output's alpha *is* the shape macOS tints
// for a light bar, a dark bar and a highlighted item. The source is a flattened export (dark ink on
// near-white paper, no alpha channel), so the paper is keyed out here rather than shipped as an
// opaque square.

import CoreGraphics
import Foundation
import ImageIO

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Design/MenuBarIcon.png")
let output = root.appendingPathComponent("Packages/NimbusSyncDesignSystem/Sources/Resources")

/// The export is neither pure black nor pure white: ink sits around 16–31 and paper around 253.
/// Values at or below `inkLevel` become fully opaque, values at or above `paperLevel` fully
/// transparent, and the anti-aliased edge in between keeps a proportional alpha.
let inkLevel = 32.0
let paperLevel = 236.0

/// 18 pt is the status-item convention; the glyph fills 16 of it so it carries the same optical
/// weight as the system items beside it.
let canvasPoints = 18
let glyphPoints = 16.0

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    fail("could not read \(source.path)")
}

let width = image.width
let height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
pixels.withUnsafeMutableBytes { buffer in
    guard let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("could not decode the source") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
}

// Key the paper out. Premultiplied, a pixel's ink coverage is its alpha minus its lightest-possible
// channel, which also passes an export that already has transparency through unchanged.
var minX = width, maxX = -1, minY = height, maxY = -1
for y in 0..<height {
    for x in 0..<width {
        let i = (y * width + x) * 4
        let alpha = Double(pixels[i + 3])
        let value = Double(min(pixels[i], min(pixels[i + 1], pixels[i + 2])))
        let paper = paperLevel * alpha / 255, ink = inkLevel * alpha / 255
        let coverage = max(0, min(1, (paper - value) / max(1, paper - ink))) * alpha / 255
        let keyed = UInt8((coverage * 255).rounded())
        pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = keyed
        if keyed >= 9 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
guard maxX >= minX, maxY >= minY else { fail("the artwork is entirely transparent") }

guard let provider = CGDataProvider(data: Data(pixels) as CFData),
      let keyedImage = CGImage(
          width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
          provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
      ),
      // Bitmap rows run top-down here, which is the orientation `cropping(to:)` expects.
      let glyph = keyedImage.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else {
    fail("could not crop the artwork")
}
print("artwork \(glyph.width)×\(glyph.height) px inside \(width)×\(height)")

try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for scale in 1...3 {
    let canvas = canvasPoints * scale
    let fit = glyphPoints * Double(scale)
    let factor = fit / Double(max(glyph.width, glyph.height))
    let drawWidth = Double(glyph.width) * factor, drawHeight = Double(glyph.height) * factor
    guard let context = CGContext(
        data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("could not make a \(canvas)² canvas") }
    context.interpolationQuality = .high
    context.draw(glyph, in: CGRect(x: (Double(canvas) - drawWidth) / 2, y: (Double(canvas) - drawHeight) / 2, width: drawWidth, height: drawHeight))
    guard let rendered = context.makeImage() else { fail("could not render @\(scale)x") }
    let suffix = scale == 1 ? "" : "@\(scale)x"
    let url = output.appendingPathComponent("MenuBarIcon\(suffix).png")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { fail("could not write \(url.path)") }
    CGImageDestinationAddImage(destination, rendered, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not finalise \(url.path)") }
    print("wrote \(url.path.replacingOccurrences(of: root.path + "/", with: "")) (\(canvas)×\(canvas))")
}
