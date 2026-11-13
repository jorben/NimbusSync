#!/usr/bin/env swift
// Regenerates the menu bar template icons from their monochrome design sheet.
//
//   Design/MenuBarIcons.png  ->  Packages/NimbusSyncDesignSystem/Sources/Resources/MenuBar*{,@2x,@3x}.png
//                            ->  Packages/NimbusSyncDesignSystem/Sources/MenuBarIconGeometry.swift
//
// Run from the repository root:  swift Scripts/make-menubar-icon.swift
//
// The sheet holds four glyphs left to right: syncing, up to date, paused, attention. They share
// one cloud, so every glyph is cut with the same crop size and drawn at the same scale; switching
// state then changes only the mark inside the cloud, never the cloud's size or position.
//
// The syncing glyph is also split into its cloud ("shell") and the arc arrow inside it, so the
// app can draw the arrow on and off around a pivot below it. The pivot and the arrow's angular
// extent are written to MenuBarIconGeometry.swift; never edit that file by hand.
//
// The status item draws every icon as a template, so the output's alpha *is* the shape macOS
// tints for a light bar, a dark bar and a highlighted item. The sheet may be a flattened export
// (dark ink on near-white paper) or already transparent; either way the ink becomes the alpha.

import CoreGraphics
import Foundation
import ImageIO

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Design/MenuBarIcons.png")
let output = root.appendingPathComponent("Packages/NimbusSyncDesignSystem/Sources/Resources")
let geometryFile = root.appendingPathComponent("Packages/NimbusSyncDesignSystem/Sources/MenuBarIconGeometry.swift")

/// Glyph names in sheet order, left to right.
let glyphNames = ["MenuBarSyncing", "MenuBarUpToDate", "MenuBarPaused", "MenuBarAttention"]

/// Ink at or below `inkLevel` becomes fully opaque, paper at or above `paperLevel` fully
/// transparent, and the anti-aliased edge in between keeps a proportional alpha.
let inkLevel = 32.0
let paperLevel = 236.0

/// The cloud is about 1.3 : 1. It fits within 20 × 16 pt of a 22 × 18 pt canvas, which puts its
/// strokes near 1.7 pt, in step with the system's own menu bar items. `MenuBarIcon.canvas` must match.
let canvasWidthPoints = 22
let canvasHeightPoints = 18
let glyphWidthPoints = 20.0
let glyphHeightPoints = 16.0
/// Transparent source pixels kept around the largest glyph, so no edge is clipped by the crop.
let cropMargin = 4
/// Gaps between glyphs on the sheet are hundreds of pixels; anything narrower is inside a glyph.
let minimumGlyphGap = 24

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
// Rows run top-down from here on (y = 0 is the top of the sheet).
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
let visible = 9.0 / 255

// Find the glyphs: runs of columns carrying ink, separated by wide empty gaps.
var columnHasInk = [Bool](repeating: false, count: width)
for x in 0..<width { columnHasInk[x] = (0..<height).contains { coverage[$0 * width + x] >= visible } }
var columnRuns: [(start: Int, end: Int)] = []
for x in 0..<width where columnHasInk[x] {
    if let last = columnRuns.last, x - last.end <= minimumGlyphGap { columnRuns[columnRuns.count - 1].end = x } else { columnRuns.append((x, x)) }
}
guard columnRuns.count == glyphNames.count else { fail("expected \(glyphNames.count) glyphs on the sheet, found \(columnRuns.count)") }

struct Box { var minX: Int, minY: Int, maxX: Int, maxY: Int
    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
}
let boxes: [Box] = columnRuns.map { run in
    var box = Box(minX: run.start, minY: height, maxX: run.end, maxY: -1)
    for y in 0..<height { for x in run.start...run.end where coverage[y * width + x] >= visible { box.minY = min(box.minY, y); box.maxY = max(box.maxY, y) } }
    return box
}

// One crop size for all four, centred on each glyph.
let cropWidth = boxes.map(\.width).max()! + cropMargin * 2
let cropHeight = boxes.map(\.height).max()! + cropMargin * 2
let crops: [Box] = boxes.map { box in
    let minX = (box.minX + box.maxX + 1 - cropWidth) / 2, minY = (box.minY + box.maxY + 1 - cropHeight) / 2
    guard minX >= 0, minY >= 0, minX + cropWidth <= width, minY + cropHeight <= height else { fail("a glyph sits too close to the sheet's edge") }
    return Box(minX: minX, minY: minY, maxX: minX + cropWidth - 1, maxY: minY + cropHeight - 1)
}
print("sheet \(width)×\(height): \(boxes.count) glyphs, crop \(cropWidth)×\(cropHeight) px each")

/// Points per source pixel, the same for every glyph.
let pointScale = min(glyphWidthPoints / Double(cropWidth - cropMargin * 2), glyphHeightPoints / Double(cropHeight - cropMargin * 2))
let drawWidthPoints = Double(cropWidth) * pointScale, drawHeightPoints = Double(cropHeight) * pointScale
let originXPoints = (Double(canvasWidthPoints) - drawWidthPoints) / 2, originYPoints = (Double(canvasHeightPoints) - drawHeightPoints) / 2

/// A source pixel (crop-relative, y down) as a canvas point (y up).
func canvasPoint(x: Double, y: Double) -> (x: Double, y: Double) {
    (originXPoints + x * pointScale, originYPoints + (Double(cropHeight) - y) * pointScale)
}

/// Writes one glyph layer at 1x, 2x and 3x. `alpha` is crop-sized, rows top-down.
func write(_ name: String, alpha: [Double]) {
    var rgba = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)
    for index in 0..<(cropWidth * cropHeight) { rgba[index * 4 + 3] = UInt8((max(0, min(1, alpha[index])) * 255).rounded()) }
    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
          let layer = CGImage(
              width: cropWidth, height: cropHeight, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cropWidth * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
              provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
          ) else { fail("could not build \(name)") }
    for scale in 1...3 {
        let canvasWidth = canvasWidthPoints * scale, canvasHeight = canvasHeightPoints * scale
        guard let context = CGContext(
            data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fail("could not make a \(canvasWidth)×\(canvasHeight) canvas") }
        context.interpolationQuality = .high
        let s = Double(scale)
        context.draw(layer, in: CGRect(x: originXPoints * s, y: originYPoints * s, width: drawWidthPoints * s, height: drawHeightPoints * s))
        guard let rendered = context.makeImage() else { fail("could not render \(name) @\(scale)x") }
        let suffix = scale == 1 ? "" : "@\(scale)x"
        let url = output.appendingPathComponent("\(name)\(suffix).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { fail("could not write \(url.path)") }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else { fail("could not finalise \(url.path)") }
        print("wrote \(url.path.replacingOccurrences(of: root.path + "/", with: "")) (\(canvasWidth)×\(canvasHeight))")
    }
}

func cropAlpha(_ crop: Box) -> [Double] {
    var alpha = [Double](repeating: 0, count: cropWidth * cropHeight)
    for y in 0..<cropHeight { for x in 0..<cropWidth { alpha[y * cropWidth + x] = coverage[(crop.minY + y) * width + crop.minX + x] } }
    return alpha
}

try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (index, name) in glyphNames.enumerated() where index > 0 { write(name, alpha: cropAlpha(crops[index])) }

// Split the syncing glyph: the largest connected shape is the cloud with its return arrow; the
// rest is the arc arrow. Solid cores are labelled first, then their soft edges are handed to
// whichever core is nearest, so neither layer loses its anti-aliasing.
let syncing = cropAlpha(crops[0])
var label = [Int](repeating: 0, count: cropWidth * cropHeight)
var sizes = [0]
for seed in 0..<(cropWidth * cropHeight) where label[seed] == 0 && syncing[seed] >= 0.5 {
    sizes.append(0)
    let id = sizes.count - 1
    var stack = [seed]
    label[seed] = id
    while let index = stack.popLast() {
        sizes[id] += 1
        let x = index % cropWidth, y = index / cropWidth
        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < cropWidth && ny < cropHeight {
            let neighbour = ny * cropWidth + nx
            if label[neighbour] == 0 && syncing[neighbour] >= 0.5 { label[neighbour] = id; stack.append(neighbour) }
        }
    }
}
guard sizes.count >= 3 else { fail("the syncing glyph should hold a cloud and a separate arrow") }
let shellID = sizes.indices.dropFirst().max { sizes[$0] < sizes[$1] }!
var frontier = (0..<(cropWidth * cropHeight)).filter { label[$0] != 0 }
while !frontier.isEmpty {
    var next: [Int] = []
    for index in frontier {
        let x = index % cropWidth, y = index / cropWidth
        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < cropWidth && ny < cropHeight {
            let neighbour = ny * cropWidth + nx
            if label[neighbour] == 0 && syncing[neighbour] > 0 { label[neighbour] = label[index]; next.append(neighbour) }
        }
    }
    frontier = next
}
let shell = syncing.indices.map { label[$0] == shellID ? syncing[$0] : 0 }
let arrow = syncing.indices.map { label[$0] != shellID && label[$0] != 0 ? syncing[$0] : 0 }
write("MenuBarSyncingShell", alpha: shell)
write("MenuBarSyncingArrow", alpha: arrow)

// The arrow is drawn on by sweeping a wedge around a pivot below it. Any pivot under the arc from
// which each ray meets the arrow once will do; this one sits under the arc's crest.
var arrowBox = Box(minX: cropWidth, minY: cropHeight, maxX: -1, maxY: -1)
for y in 0..<cropHeight { for x in 0..<cropWidth where arrow[y * cropWidth + x] >= visible {
    arrowBox.minX = min(arrowBox.minX, x); arrowBox.maxX = max(arrowBox.maxX, x)
    arrowBox.minY = min(arrowBox.minY, y); arrowBox.maxY = max(arrowBox.maxY, y)
} }
let pivotSource = (x: Double(arrowBox.minX) + Double(arrowBox.width) * 0.62, y: Double(arrowBox.maxY) + Double(arrowBox.height) * 0.3)
var lowestAngle = Double.infinity, highestAngle = -Double.infinity
for y in 0..<cropHeight { for x in 0..<cropWidth where arrow[y * cropWidth + x] >= visible {
    // y down to y up, so angles read the same as on the canvas.
    let angle = atan2(pivotSource.y - (Double(y) + 0.5), Double(x) + 0.5 - pivotSource.x) * 180 / .pi
    lowestAngle = min(lowestAngle, angle); highestAngle = max(highestAngle, angle)
} }
guard lowestAngle > 0, highestAngle < 180 else { fail("the sweep pivot must sit below the whole arrow") }
let pivot = canvasPoint(x: pivotSource.x, y: pivotSource.y)
print("arrow sweep: pivot (\(String(format: "%.3f", pivot.x)), \(String(format: "%.3f", pivot.y))) pt, \(String(format: "%.1f", highestAngle))° (tail) → \(String(format: "%.1f", lowestAngle))° (head)")

let geometry = """
// Generated by Scripts/make-menubar-icon.swift from Design/MenuBarIcons.png. Do not edit.

import CoreGraphics

extension MenuBarIcon {
    /// Canvas the generator drew every glyph into, in points.
    nonisolated static let generatedCanvas = CGSize(width: \(canvasWidthPoints), height: \(canvasHeightPoints))
    /// Where the arc arrow's draw-on wedge turns, in canvas points (y up).
    nonisolated static let arrowSweepPivot = CGPoint(x: \(String(format: "%.3f", pivot.x)), y: \(String(format: "%.3f", pivot.y)))
    /// The arrow's tail and head as angles around the pivot, in degrees (counter-clockwise from +x).
    nonisolated static let arrowTailAngle: CGFloat = \(String(format: "%.2f", highestAngle))
    nonisolated static let arrowHeadAngle: CGFloat = \(String(format: "%.2f", lowestAngle))
}

"""
do { try geometry.write(to: geometryFile, atomically: true, encoding: .utf8) } catch { fail("could not write \(geometryFile.path)") }
print("wrote \(geometryFile.path.replacingOccurrences(of: root.path + "/", with: ""))")
