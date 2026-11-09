import AppKit
import SwiftUI

/// The menu bar glyph and its syncing animation.
///
/// **Always a template.** A template image is drawn in the menu bar's own ink, which is what keeps
/// the icon right on a light bar, a dark one, a highlighted item and under reduced transparency.
/// The syncing state therefore adds motion, not colour: the glyph is a cloud over an infinity
/// track carrying two nodes, and while syncing the filled node runs laps of the track with a short
/// fading tail, the way the app icon's artwork draws it in motion. The ring stays put: it is where
/// the cloud joins the track.
///
/// The size never changes while animating; a status item that widened during every transfer would
/// shove its neighbours along with it.
@MainActor
public enum MenuBarIcon {
    public static let frameCount = 36
    /// One lap every 2.4 s.
    public static let frameInterval: TimeInterval = 1.0 / 15
    /// Matches `Scripts/make-menubar-icon.swift`: the wide glyph fits 20 × 16 pt of it.
    public nonisolated static let canvas = NSSize(width: 22, height: 18)

    /// The bundled glyph (`Scripts/make-menubar-icon.swift` builds it from `Design/MenuBarIcon.png`).
    /// Falls back to an SF Symbol so a missing resource degrades to a plain icon, not an empty item.
    public static let base: NSImage = {
        let image: NSImage
        if let bundled = Bundle.module.image(forResource: "MenuBarIcon") {
            bundled.size = canvas
            image = bundled
        } else {
            image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil) ?? NSImage(size: canvas)
        }
        image.isTemplate = true
        image.accessibilityDescription = "NimbusSync"
        return image
    }()

    /// One full lap of the syncing animation, rendered once and reused. Frame 0 starts from the
    /// node's resting place, so the idle glyph flows straight into the animation.
    public static let syncingFrames: [NSImage] = (0..<frameCount).map {
        syncingImage(progress: Double($0) / Double(frameCount))
    }

    /// Reduce Motion gets the node moved off its resting place, without the movement.
    public static let syncingStill: NSImage = syncingImage(progress: 0.25)

    // MARK: - Artwork geometry

    /// Measured on `Design/MenuBarIcon.png` (1024 px, y pointing down) after the generator grows
    /// the ink by `strokeGrowth` (18 px). Re-measure if the artwork or the growth changes; the
    /// generator script prints the crop.
    nonisolated static let artworkCrop = CGRect(x: 125, y: 269, width: 772, height: 492)
    nonisolated static let glyphFit = CGSize(width: 20, height: 16)
    /// The infinity track as a generalised lemniscate,
    /// x = cx + a·cos t / (1 + sin²t), y = cy + b·sin t·cos t / (1 + sin²t),
    /// fitted to the stroke's centre line (mean offset 1.7 px against the source's 33 px stroke).
    /// Growing the ink keeps the centre line, so the fit still holds.
    nonisolated static let track = (cx: 510.0, cy: 568.0, a: 350.0, b: 380.0)
    /// The source's 33 px stroke and 46 px node, each grown by the generator's 18 px per edge.
    nonisolated static let trackWidth = 69.0
    nonisolated static let nodeCenter = CGPoint(x: 283, y: 696)
    nonisolated static let nodeRadius = 64.0

    nonisolated static var artworkScale: CGFloat {
        min(glyphFit.width / artworkCrop.width, glyphFit.height / artworkCrop.height)
    }

    /// Artwork pixel (y down) to canvas point (y up), as the generator placed the glyph.
    nonisolated static func canvasPoint(_ point: CGPoint) -> CGPoint {
        let scale = artworkScale
        let originX = (canvas.width - artworkCrop.width * scale) / 2
        let originY = (canvas.height - artworkCrop.height * scale) / 2
        return CGPoint(x: originX + (point.x - artworkCrop.minX) * scale, y: originY + (artworkCrop.maxY - point.y) * scale)
    }

    nonisolated static func trackPoint(_ t: Double) -> CGPoint {
        let sine = sin(t), denominator = 1 + sine * sine
        return CGPoint(x: track.cx + track.a * cos(t) / denominator, y: track.cy + track.b * sine * cos(t) / denominator)
    }

    /// The track sampled evenly by length, starting where the node rests and running the way the
    /// artwork's motion trail points (away from the trail, round the left loop first).
    nonisolated static let lap: [CGPoint] = {
        let samples = 1_440
        var restT = 0.0, restDistance = Double.infinity
        for index in 0..<samples {
            let t = Double(index) / Double(samples) * 2 * .pi
            let point = trackPoint(t)
            let distance = hypot(point.x - nodeCenter.x, point.y - nodeCenter.y)
            if distance < restDistance { restDistance = distance; restT = t }
        }
        // Decreasing t from the resting place heads for the left end of the track.
        let raw = (0...samples).map { trackPoint(restT - Double($0) / Double(samples) * 2 * .pi) }
        var lengths = [0.0]
        for index in 1..<raw.count { lengths.append(lengths[index - 1] + hypot(raw[index].x - raw[index - 1].x, raw[index].y - raw[index - 1].y)) }
        let total = lengths.last ?? 1
        var even: [CGPoint] = []
        var cursor = 0
        for step in 0..<samples {
            let target = Double(step) / Double(samples) * total
            while cursor < lengths.count - 2 && lengths[cursor + 1] < target { cursor += 1 }
            let span = max(lengths[cursor + 1] - lengths[cursor], .ulpOfOne)
            let fraction = (target - lengths[cursor]) / span
            even.append(CGPoint(x: raw[cursor].x + (raw[cursor + 1].x - raw[cursor].x) * fraction, y: raw[cursor].y + (raw[cursor + 1].y - raw[cursor].y) * fraction))
        }
        return even
    }()

    /// The node's position (artwork pixels) after `progress` of a lap, wrapping both ways.
    nonisolated static func nodePosition(_ progress: Double) -> CGPoint {
        let wrapped = progress - progress.rounded(.down)
        return lap[min(lap.count - 1, Int(wrapped * Double(lap.count)))]
    }

    /// Fading copies behind the node: (lap distance behind, size, opacity).
    nonisolated static let tail: [(behind: Double, size: Double, opacity: Double)] = [(0.02, 0.8, 0.5), (0.04, 0.62, 0.3), (0.06, 0.46, 0.15)]

    static func syncingImage(progress: Double) -> NSImage {
        let base = base
        let image = NSImage(size: canvas, flipped: false) { rect in
            base.draw(in: rect)
            let scale = artworkScale
            let rest = canvasPoint(nodeCenter)
            // Lift the resting node off the track, then restore the stretch of track it covered.
            // The bundled glyph is downsampled (one Retina pixel spans about 18 artwork pixels),
            // so the node's soft edge reaches well past its radius; a tighter cut left a
            // faint ring behind. The repair is clipped wider than the cut, so it meets the
            // original stroke where that stroke is still whole and leaves no seam.
            let cut = (nodeRadius + 24) * scale, repair = (nodeRadius + 36) * scale
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: NSRect(x: rest.x - cut, y: rest.y - cut, width: cut * 2, height: cut * 2)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: NSRect(x: rest.x - repair, y: rest.y - repair, width: repair * 2, height: repair * 2)).addClip()
            let path = NSBezierPath()
            for (index, point) in lap.enumerated() {
                let canvasPoint = canvasPoint(point)
                index == 0 ? path.move(to: canvasPoint) : path.line(to: canvasPoint)
            }
            path.close()
            path.lineWidth = trackWidth * scale
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()

            func node(at progress: Double, size: Double, opacity: Double) {
                let center = canvasPoint(nodePosition(progress))
                let radius = nodeRadius * scale * size
                NSColor.black.withAlphaComponent(opacity).setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
            }
            for piece in tail.reversed() { node(at: progress - piece.behind, size: piece.size, opacity: piece.opacity) }
            node(at: progress, size: 1, opacity: 1)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "NimbusSync – Syncing"
        return image
    }
}

/// Drives the menu bar image from a single "is anything syncing" flag.
///
/// The image is a function of that flag, never of an event: it animates while the flag is true and
/// returns to the plain glyph the moment it turns false, with nothing to dismiss.
@MainActor
public final class MenuBarIconAnimator: ObservableObject {
    @Published public private(set) var image: NSImage = MenuBarIcon.base
    @Published public private(set) var isSyncing = false
    /// The status item's hover text (see `MenuBarStatusSummary.tooltip`).
    @Published public private(set) var tooltip = "NimbusSync"
    private var timer: Timer?
    private var frame = 0

    public init() {}

    public func setTooltip(_ text: String) {
        if text != tooltip { tooltip = text }
        StatusItemToolTip.apply(text)
    }

    public func setSyncing(_ syncing: Bool) {
        guard syncing != isSyncing else { return }
        isSyncing = syncing
        syncing ? start() : stop()
    }

    private func start() {
        frame = 0
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            image = MenuBarIcon.syncingStill
            return
        }
        image = MenuBarIcon.syncingFrames[0]
        let timer = Timer(timeInterval: MenuBarIcon.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        // `.common` keeps the animation running while a menu or the popover is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func advance() {
        frame = (frame + 1) % MenuBarIcon.frameCount
        image = MenuBarIcon.syncingFrames[frame]
        // A label redraw may reset the button; restoring is a string compare when nothing changed.
        StatusItemToolTip.apply(tooltip)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        image = MenuBarIcon.base
    }
}

/// The `MenuBarExtra` label.
public struct MenuBarIconLabel: View {
    @ObservedObject private var animator: MenuBarIconAnimator

    public init(animator: MenuBarIconAnimator) {
        self.animator = animator
    }

    public var body: some View {
        Image(nsImage: animator.image)
            .renderingMode(.template)
            .accessibilityLabel(animator.isSyncing ? "NimbusSync – Syncing" : "NimbusSync")
            .help(animator.tooltip)
    }
}

/// `MenuBarExtra` has no tooltip API. Its status item is an `NSStatusBarButton` inside this app's
/// own `NSStatusBarWindow`, so the hover text is set on that button directly.
@MainActor
public enum StatusItemToolTip {
    public static func apply(_ text: String) {
        for window in NSApp?.windows ?? [] where window.className.contains("NSStatusBarWindow") {
            guard let button = statusButton(in: window.contentView), button.toolTip != text else { continue }
            button.toolTip = text
        }
    }

    static func statusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = statusButton(in: subview) { return button }
        }
        return nil
    }
}
