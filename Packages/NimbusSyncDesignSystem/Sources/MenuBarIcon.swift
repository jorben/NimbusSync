import AppKit
import SwiftUI

/// The menu bar glyph and its syncing animation.
///
/// **Always a template.** A template image is drawn in the menu bar's own ink, which is what keeps
/// the icon right on a light bar, a dark one, a highlighted item and under reduced transparency.
/// The syncing state therefore adds shape, not colour: a pair of arrows drifts inside the glyph's
/// cloud — the open area in its lower half — so the moon and the ring stay whole. They are punched
/// out before they are drawn, so they keep their own edge where they brush the cloud's outline.
///
/// The size never changes while animating; a status item that widened during every transfer would
/// shove its neighbours along with it.
@MainActor
public enum MenuBarIcon {
    public static let frameCount = 10
    public static let frameInterval: TimeInterval = 0.09
    public static let canvas = NSSize(width: 18, height: 18)

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

    /// One full cycle of the syncing animation, rendered once and reused.
    public static let syncingFrames: [NSImage] = (0..<frameCount).map {
        syncingImage(phase: Double($0) / Double(frameCount))
    }

    /// Reduce Motion gets the arrows without the movement.
    public static let syncingStill: NSImage = syncingImage(phase: 0.5)

    static func syncingImage(phase: Double) -> NSImage {
        let base = base
        let image = NSImage(size: canvas, flipped: false) { rect in
            base.draw(in: rect)
            // Measured from the generated glyph: the cloud is open from y ≈ 2.0 to 7.7 pt around
            // x 6–9 and to ≈ 6.3 pt by x 11, so the pair sits low and left of centre. Re-measure
            // if Design/MenuBarIcon.png is redrawn.
            let box = NSRect(x: 5.75, y: 2.9, width: 4.9, height: 3.6)
            // Cut first, paint after, so the arrows never blend into the glyph's ink.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            drawArrows(in: box, phase: phase, cut: true)
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            drawArrows(in: box, phase: phase, cut: false)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "NimbusSync – Syncing"
        return image
    }

    /// An up arrow and a down arrow side by side, drifting in opposite directions and trading
    /// brightness, so the pair reads as traffic both ways.
    private static func drawArrows(in box: NSRect, phase: Double, cut: Bool) {
        let lineWidth: CGFloat = 1.0, gap: CGFloat = 0.5, wingSpan: CGFloat = 1.25, amplitude: CGFloat = 0.35
        func arrow(centerX: CGFloat, up: Bool, phase: Double) {
            let travel = (CGFloat(phase) * 2 - 1) * amplitude      // -amplitude → +amplitude per cycle
            let shift = up ? travel : -travel
            let alpha = 0.45 + 0.55 * sin(.pi * phase)
            let top = box.maxY - amplitude, bottom = box.minY + amplitude
            let tip = up ? top : bottom, tail = up ? bottom : top
            let wing = wingSpan * (up ? -1 : 1)

            let path = NSBezierPath()
            // A cut is the same path stroked wider at full opacity: a half-faded arrow must not
            // leave a half-faded gap.
            path.lineWidth = cut ? lineWidth + 2 * gap : lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: NSPoint(x: centerX, y: tail + shift))
            path.line(to: NSPoint(x: centerX, y: tip + shift))
            path.move(to: NSPoint(x: centerX - wingSpan, y: tip + shift + wing))
            path.line(to: NSPoint(x: centerX, y: tip + shift))
            path.line(to: NSPoint(x: centerX + wingSpan, y: tip + shift + wing))
            NSColor.black.withAlphaComponent(cut ? 1 : alpha).setStroke()
            path.stroke()
        }
        arrow(centerX: box.minX + wingSpan, up: true, phase: phase)
        arrow(centerX: box.maxX - wingSpan, up: false, phase: (phase + 0.5).truncatingRemainder(dividingBy: 1))
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
