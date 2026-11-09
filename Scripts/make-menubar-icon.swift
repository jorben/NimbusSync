#!/usr/bin/env swift
// Regenerates the menu bar template icon from its monochrome design source.
//
//   Design/MenuBarIcon.png  ->  Packages/NimbusSyncDesignSystem/Sources/Resources/MenuBarIcon{,@2x,@3x}.png
//
// Run from the repository root:  swift Scripts/make-menubar-icon.swift
//
// The status item draws the icon as a template, so the output's alpha *is* the shape macOS tints
// for a light bar, a dark bar and a highlighted item. A source may be a flattened export (dark ink
// on near-white paper) or already transparent; either way the ink becomes the alpha here, so no
// opaque square is ever shipped.

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

/// The glyph is a wide cloud-and-infinity mark (about 1.6 : 1). Squeezed into the usual 18 pt
/// square its strokes came out near 0.7 pt and read faint beside the system items, so the canvas
/// is 22 × 18 pt and the glyph fits within 20 × 16 pt of it. `MenuBarIcon.canvas` must match.
let canvasWidthPoints = 22
let canvasHeightPoints = 18
let glyphWidthPoints = 20.0
let glyphHeightPoints = 16.0

/// The design source draws its track with a 33 px stroke (on a 1024 px canvas); at menu bar size
/// that came out under 0.9 pt and read thin beside the system items. Every ink edge is pushed out
/// by this many source pixels, so the stroke grows to 69 px: the grown glyph is wider, so it is drawn a little smaller, and
/// 69 px is what lands at twice the old on-screen stroke (about 1.8 pt against 0.9 pt). Small enclosed holes
/// (the open ring) are kept as drawn so the ring stays hollow instead of filling in.
/// `MenuBarIcon.trackWidth`, `nodeRadius` and `artworkCrop` must match the grown glyph.
let strokeGrowth = 18.0
/// Enclosed background regions smaller than this (source px²) are holes to keep open.
let preservedHoleArea = 8_000

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
var coverage = [Double](repeating: 0, count: width * height)
for y in 0..<height {
    for x in 0..<width {
        let i = (y * width + x) * 4
        let alpha = Double(pixels[i + 3])
        let value = Double(min(pixels[i], min(pixels[i + 1], pixels[i + 2])))
        let paper = paperLevel * alpha / 255, ink = inkLevel * alpha / 255
        coverage[y * width + x] = max(0, min(1, (paper - value) / max(1, paper - ink))) * alpha / 255
    }
}

// Find the small enclosed holes before growing, so they can be left as drawn.
var preserved = [Bool](repeating: false, count: width * height)
do {
    var label = [Int32](repeating: 0, count: width * height)
    var nextLabel: Int32 = 0
    for seed in 0..<(width * height) where label[seed] == 0 && coverage[seed] < 0.5 {
        nextLabel += 1
        var stack = [seed], members: [Int] = [], touchesBorder = false
        label[seed] = nextLabel
        while let index = stack.popLast() {
            members.append(index)
            let x = index % width, y = index / width
            if x == 0 || y == 0 || x == width - 1 || y == height - 1 { touchesBorder = true }
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < width && ny < height {
                let neighbour = ny * width + nx
                if label[neighbour] == 0 && coverage[neighbour] < 0.5 { label[neighbour] = nextLabel; stack.append(neighbour) }
            }
        }
        if !touchesBorder && members.count < preservedHoleArea { for index in members { preserved[index] = true } }
    }
}

/// Squared Euclidean distance transform of one line (Felzenszwalb & Huttenlocher).
func distanceTransform(_ f: [Double]) -> [Double] {
    let n = f.count
    var d = [Double](repeating: 0, count: n), v = [Int](repeating: 0, count: n), z = [Double](repeating: 0, count: n + 1)
    var k = 0
    z[0] = -.infinity; z[1] = .infinity
    for q in 1..<n {
        var s = ((f[q] + Double(q * q)) - (f[v[k]] + Double(v[k] * v[k]))) / Double(2 * q - 2 * v[k])
        while s <= z[k] { k -= 1; s = ((f[q] + Double(q * q)) - (f[v[k]] + Double(v[k] * v[k]))) / Double(2 * q - 2 * v[k]) }
        k += 1; v[k] = q; z[k] = s; z[k + 1] = .infinity
    }
    k = 0
    for q in 0..<n {
        while z[k + 1] < Double(q) { k += 1 }
        d[q] = Double((q - v[k]) * (q - v[k])) + f[v[k]]
    }
    return d
}

// Grow the ink: each pixel's new coverage comes from its distance to the nearest solid ink pixel.
let far = Double(width * width + height * height)
var squared = coverage.map { $0 >= 0.5 ? 0 : far }
for x in 0..<width {
    let column = distanceTransform((0..<height).map { squared[$0 * width + x] })
    for y in 0..<height { squared[y * width + x] = column[y] }
}
for y in 0..<height {
    let row = distanceTransform(Array(squared[(y * width)..<((y + 1) * width)]))
    for x in 0..<width { squared[y * width + x] = row[x] }
}

var minX = width, maxX = -1, minY = height, maxY = -1
for y in 0..<height {
    for x in 0..<width {
        let index = y * width + x, i = index * 4
        let grown = preserved[index] ? coverage[index] : max(coverage[index], min(1, max(0, strokeGrowth + 0.5 - squared[index].squareRoot())))
        let keyed = UInt8((grown * 255).rounded())
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
print("crop origin (\(minX), \(minY)) size \(glyph.width)×\(glyph.height): MenuBarIcon.artworkCrop must match")
for scale in 1...3 {
    let canvasWidth = canvasWidthPoints * scale, canvasHeight = canvasHeightPoints * scale
    let factor = min(glyphWidthPoints / Double(glyph.width), glyphHeightPoints / Double(glyph.height)) * Double(scale)
    let drawWidth = Double(glyph.width) * factor, drawHeight = Double(glyph.height) * factor
    guard let context = CGContext(
        data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("could not make a \(canvasWidth)×\(canvasHeight) canvas") }
    context.interpolationQuality = .high
    context.draw(glyph, in: CGRect(x: (Double(canvasWidth) - drawWidth) / 2, y: (Double(canvasHeight) - drawHeight) / 2, width: drawWidth, height: drawHeight))
    guard let rendered = context.makeImage() else { fail("could not render @\(scale)x") }
    let suffix = scale == 1 ? "" : "@\(scale)x"
    let url = output.appendingPathComponent("MenuBarIcon\(suffix).png")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { fail("could not write \(url.path)") }
    CGImageDestinationAddImage(destination, rendered, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not finalise \(url.path)") }
    print("wrote \(url.path.replacingOccurrences(of: root.path + "/", with: "")) (\(canvasWidth)×\(canvasHeight))")
}
