import AppKit
import Combine
import SwiftUI

/// The menu bar item and the panel it opens.
///
/// This replaces SwiftUI's `MenuBarExtra`. On recent macOS the extra's status item is a scene item
/// whose button has no target, action or gesture recognizer: the panel is presented by a private
/// "expanded interface" session, so nothing outside the menu bar (the Dock icon, in particular)
/// can open or close it. Owning the status item and the panel makes `toggle()` work from anywhere.
///
/// The panel behaves like the extra's window: it hangs under the item, takes key focus without
/// activating the app, and closes on Escape, on a click anywhere else, or when another window
/// becomes key.
@MainActor
public final class MenuBarPanelController: NSObject, NSWindowDelegate {
    /// A dismissal this recent is taken to be caused by the click that is now asking to toggle.
    public nonisolated static let dismissalGrace: TimeInterval = 0.4
    static let panelGap: CGFloat = 5
    static let screenMargin: CGFloat = 8
    static let cornerRadius: CGFloat = 12

    private let statusItem: NSStatusItem
    private let panel: MenuBarPanel
    private var cancellables: Set<AnyCancellable> = []
    private var outsideClickMonitor: Any?
    private var lastDismissedAt: Date?
    private var isClosing = false
    /// The latest measured content size, waiting to be applied to the panel.
    private var pendingContentSize: CGSize?

    public init<Content: View>(icon: MenuBarIconAnimator, @ViewBuilder content: () -> Content) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = MenuBarPanel()
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.imagePosition = .imageOnly
        }
        icon.$image
            .sink { [weak self] image in self?.statusItem.button?.image = image }
            .store(in: &cancellables)
        icon.$tooltip
            .sink { [weak self] text in self?.statusItem.button?.toolTip = text }
            .store(in: &cancellables)
        icon.$accessibilityLabel
            .sink { [weak self] label in self?.statusItem.button?.setAccessibilityLabel(label) }
            .store(in: &cancellables)

        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        panel.contentView = Self.makeContainer(
            content: content(),
            onSizeChange: { [weak self] size in self?.scheduleResize(to: size) }
        )

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(dismissForNotification(_:)), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // The panel never activates the app, so another app coming forward (Finder opened from a
        // panel row, say) does not make it resign key; this does.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(otherApplicationDidActivate(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(dismissForNotification(_:)), name: NSApplication.didHideNotification, object: nil)
    }

    public var isPanelShown: Bool { panel.isVisible }

    /// Opens the panel if it is closed and closes it if it is open, the same as clicking the item.
    public func toggle() {
        let shouldOpen = Self.shouldOpenOnToggle(isPanelVisible: panel.isVisible, lastDismissedAt: lastDismissedAt, now: Date())
        lastDismissedAt = nil
        shouldOpen ? open() : close()
    }

    /// A click that lands outside an open panel closes it before the click itself is handled (the
    /// Dock icon's reopen event, the status item's own action). Without the grace window that same
    /// click would reopen the panel at once.
    public nonisolated static func shouldOpenOnToggle(isPanelVisible: Bool, lastDismissedAt: Date?, now: Date) -> Bool {
        if isPanelVisible { return false }
        guard let lastDismissedAt else { return true }
        return now.timeIntervalSince(lastDismissedAt) > dismissalGrace
    }

    public func open() {
        guard !panel.isVisible else { return }
        applyPendingResize()
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    public func close() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        statusItem.button?.highlight(false)
        // Ordered out even when not visible: a panel hidden along with the app would otherwise
        // come back on unhide.
        isClosing = true
        panel.orderOut(nil)
        isClosing = false
    }

    /// Closing for any reason other than an explicit toggle; remembered for the grace window.
    private func dismiss() {
        guard panel.isVisible, !isClosing else { return }
        lastDismissedAt = Date()
        close()
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        toggle()
    }

    @objc private func otherApplicationDidActivate(_ notification: Notification) {
        let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard activated?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        dismiss()
    }

    @objc private func dismissForNotification(_ notification: Notification) {
        dismiss()
        if !panel.isVisible { close() }
    }

    public func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    // MARK: Layout

    private static func makeContainer<Content: View>(content: Content, onSizeChange: @escaping @MainActor (CGSize) -> Void) -> NSView {
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.maskImage = roundedMask(radius: cornerRadius)

        let hosting = NSHostingView(rootView: content
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                onSizeChange(size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        )
        // The panel is sized from the measured content, never by the hosting view's constraints:
        // those would grow the window from its bottom edge and lift it off the menu bar.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: material.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])
        return material
    }

    /// A stretchable rounded-rectangle mask: the corners stay round at any panel size.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// The size arrives from SwiftUI's geometry callback, which runs while the hosting view is
    /// rendering. Resizing the panel there lays the hosting view out reentrantly; AppKit skips that
    /// pass and SwiftUI keeps the previous size, so content that shrank and grew again is drawn
    /// shifted up, with an empty band at the bottom and nothing left to scroll. The resize waits
    /// for the render to finish, and only the latest size is applied.
    private func scheduleResize(to size: CGSize) {
        let isScheduled = pendingContentSize != nil
        pendingContentSize = size
        guard !isScheduled else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.applyPendingResize() }
        }
    }

    private func applyPendingResize() {
        guard let size = pendingContentSize else { return }
        pendingContentSize = nil
        resizePanel(to: size)
    }

    /// Keeps the panel's top edge where it is, so content growing or shrinking moves the bottom.
    private func resizePanel(to size: CGSize) {
        guard size.width > 0, size.height > 0, panel.frame.size != size else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        setPanelFrame(frame)
        if panel.isVisible { positionPanel() }
    }

    /// Under the item, left edges aligned, kept on the item's screen.
    private func positionPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let itemRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(itemRect) }) ?? NSScreen.main
        var size = panel.frame.size
        if size.width <= 1 || size.height <= 1 {
            size = panel.contentView?.fittingSize ?? size
        }
        var origin = NSPoint(x: itemRect.minX, y: itemRect.minY - Self.panelGap - size.height)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + Self.screenMargin), visible.maxX - Self.screenMargin - size.width)
            origin.y = max(origin.y, visible.minY + Self.screenMargin)
        }
        setPanelFrame(NSRect(origin: origin, size: size))
    }

    /// The content view is laid out explicitly: autoresizing from the panel's 1 × 1 starting size
    /// scales it wrongly and pushes the content out of the visible area.
    private func setPanelFrame(_ frame: NSRect) {
        panel.setFrame(frame, display: false)
        panel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        panel.displayIfNeeded()
    }
}

/// A borderless panel that can take keyboard focus without activating the app.
final class MenuBarPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
