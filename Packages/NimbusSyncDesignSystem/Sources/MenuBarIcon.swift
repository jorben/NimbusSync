import AppKit
import CloudreveDomainKit
import SwiftUI

/// What the menu bar glyph shows, from the most to the least urgent.
///
/// - `attention`: a conflict waits for the user, or a Domain needs them (sign-in expired, folder
///   gone, permanent error…). It outranks syncing, as the status summary's headline does.
/// - `syncing`: `ProductSnapshot.isSyncing`, a transfer is queued or running, or a Domain is
///   applying or checking remote changes.
/// - `paused`: a Domain is offline, so its syncing waits for the network. NimbusSync has no
///   user-facing pause; offline is the state that actually holds syncing back.
/// - `upToDate`: everything else, including no Domains yet.
public enum MenuBarIconState: Equatable, Sendable {
    case upToDate, syncing, paused, attention

    public init(domains: [DomainDescriptor], isSyncing: Bool, hasActionableConflicts: Bool) {
        if hasActionableConflicts || domains.contains(where: { $0.status.needsAttention && $0.status != .offline }) {
            self = .attention
        } else if isSyncing {
            self = .syncing
        } else if domains.contains(where: { $0.status == .offline }) {
            self = .paused
        } else {
            self = .upToDate
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .upToDate: "NimbusSync – Up to date"
        case .syncing: "NimbusSync – Syncing"
        case .paused: "NimbusSync – Paused"
        case .attention: "NimbusSync – Needs attention"
        }
    }
}

/// The menu bar glyphs and the syncing animation.
///
/// **Always a template.** A template image is drawn in the menu bar's own ink, which is what keeps
/// the icon right on a light bar, a dark one, a highlighted item and under reduced transparency.
/// States therefore differ by the mark inside the cloud, and syncing adds motion, not colour: the
/// arc arrow inside the cloud is drawn on from its tail to its head, holds, then is wiped away
/// tail first, so it reads as one stroke flowing round in the arrow's direction. The cloud and
/// its return arrow stay put.
///
/// Every glyph shares one canvas and one cloud (see `Scripts/make-menubar-icon.swift`), so
/// switching state never changes the status item's width or shoves its neighbours along.
@MainActor
public enum MenuBarIcon {
    /// One draw-on / wipe-off cycle every 1.6 s.
    public static let frameCount = 32
    public static let frameInterval: TimeInterval = 1.0 / 20
    public nonisolated static let canvas = NSSize(width: generatedCanvas.width, height: generatedCanvas.height)

    public static let upToDate = glyph("MenuBarUpToDate", state: .upToDate, fallback: "checkmark.icloud")
    public static let paused = glyph("MenuBarPaused", state: .paused, fallback: "pause.circle")
    public static let attention = glyph("MenuBarAttention", state: .attention, fallback: "exclamationmark.icloud")
    /// The cloud with its return arrow, without the arc arrow; also the neutral glyph shown before
    /// the first status arrives.
    public static let syncingShell = glyph("MenuBarSyncingShell", state: nil, fallback: "icloud")
    static let syncingArrow: NSImage? = Bundle.module.image(forResource: "MenuBarSyncingArrow")

    /// One cycle of the syncing animation, rendered once and reused. Frame 0 is the bare cloud, so
    /// the arrow always enters from its tail.
    public static let syncingFrames: [NSImage] = (0..<frameCount).map {
        syncingImage(progress: Double($0) / Double(frameCount))
    }

    /// Reduce Motion gets the whole syncing glyph, without the movement.
    public static let syncingStill: NSImage = syncingImage(visible: 0...1)

    /// The still glyph for a state; syncing animates through `syncingFrames` instead.
    public static func still(_ state: MenuBarIconState) -> NSImage {
        switch state {
        case .upToDate: upToDate
        case .syncing: syncingStill
        case .paused: paused
        case .attention: attention
        }
    }

    /// A bundled glyph (`Scripts/make-menubar-icon.swift` builds them from `Design/MenuBarIcons.png`).
    /// Falls back to an SF Symbol so a missing resource degrades to a plain icon, not an empty item.
    private static func glyph(_ name: String, state: MenuBarIconState?, fallback: String) -> NSImage {
        let image: NSImage
        if let bundled = Bundle.module.image(forResource: name) {
            bundled.size = canvas
            image = bundled
        } else {
            image = NSImage(systemSymbolName: fallback, accessibilityDescription: nil) ?? NSImage(size: canvas)
        }
        image.isTemplate = true
        image.accessibilityDescription = state?.accessibilityLabel ?? "NimbusSync"
        return image
    }

    // MARK: - Syncing animation

    private nonisolated static let drawOnEnd = 0.45, holdEnd = 0.6
    /// How far the tail retracts while the arrow leaves; the head is never sliced, it fades.
    private nonisolated static let wipeReach = 0.7

    private nonisolated static func ease(_ t: Double) -> Double { let t = max(0, min(1, t)); return t * t * (3 - 2 * t) }

    /// The stretch of the arc arrow shown at `progress` through a cycle, as fractions of its
    /// length from tail (0) to head (1): drawn on, held, then retracted tail first.
    public nonisolated static func visibleSpan(_ progress: Double) -> ClosedRange<Double>? {
        let wrapped = progress - progress.rounded(.down)
        let span: ClosedRange<Double>
        if wrapped < drawOnEnd {
            span = 0...ease(wrapped / drawOnEnd)
        } else if wrapped < holdEnd {
            span = 0...1
        } else {
            span = (wipeReach * ease((wrapped - holdEnd) / (1 - holdEnd)))...1
        }
        return span.upperBound - span.lowerBound > 0.001 ? span : nil
    }

    /// The arrow's opacity at `progress`: whole until the retracting tail is halfway, then fading
    /// to nothing by the end of the cycle.
    public nonisolated static func arrowOpacity(_ progress: Double) -> Double {
        let wrapped = progress - progress.rounded(.down)
        guard wrapped >= holdEnd else { return 1 }
        return 1 - ease(((wrapped - holdEnd) / (1 - holdEnd) - 0.35) / 0.65)
    }

    static func syncingImage(progress: Double) -> NSImage {
        let opacity = arrowOpacity(progress)
        guard let span = visibleSpan(progress), opacity > 0.02 else { return syncingShell }
        return syncingImage(visible: span, opacity: opacity)
    }

    /// The cloud plus the part of the arc arrow inside `visible`. The arrow is clipped to a wedge
    /// around a pivot below it; every ray from the pivot crosses the arrow once, so the wedge's
    /// angle maps straight to a position along it.
    static func syncingImage(visible: ClosedRange<Double>, opacity: Double = 1) -> NSImage {
        let shell = syncingShell
        guard let arrow = syncingArrow else { return shell }
        let image = NSImage(size: canvas, flipped: false) { rect in
            shell.draw(in: rect)
            // A few degrees past each end, so the tail's round cap and the head's tip are whole.
            let margin: CGFloat = 4
            let tail = arrowTailAngle + margin, head = arrowHeadAngle - margin
            func angle(_ fraction: Double) -> CGFloat { tail - (tail - head) * CGFloat(fraction) }
            let wedge = NSBezierPath()
            wedge.move(to: arrowSweepPivot)
            wedge.appendArc(withCenter: arrowSweepPivot, radius: canvas.width * 2, startAngle: angle(visible.upperBound), endAngle: angle(visible.lowerBound))
            wedge.close()
            NSGraphicsContext.saveGraphicsState()
            wedge.addClip()
            arrow.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = MenuBarIconState.syncing.accessibilityLabel
        return image
    }
}

/// Drives the menu bar image from the current `MenuBarIconState`.
///
/// The image is a function of the state, never of an event: it animates while syncing and settles
/// on the state's still glyph the moment syncing ends, with nothing to dismiss.
@MainActor
public final class MenuBarIconAnimator: ObservableObject {
    @Published public private(set) var image: NSImage = MenuBarIcon.syncingShell
    /// Nil until the first status arrives.
    @Published public private(set) var state: MenuBarIconState?
    @Published public private(set) var isSyncing = false
    /// The status item's VoiceOver label.
    @Published public private(set) var accessibilityLabel = "NimbusSync"
    /// The status item's hover text (see `MenuBarStatusSummary.tooltip`).
    @Published public private(set) var tooltip = "NimbusSync"
    private var timer: Timer?
    private var frame = 0

    public init() {}

    public func setTooltip(_ text: String) {
        if text != tooltip { tooltip = text }
    }

    public func setState(_ next: MenuBarIconState) {
        guard next != state else { return }
        state = next
        isSyncing = next == .syncing
        accessibilityLabel = next.accessibilityLabel
        if next == .syncing {
            start()
        } else {
            stop()
            image = MenuBarIcon.still(next)
        }
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
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}
