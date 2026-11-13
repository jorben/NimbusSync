import XCTest
import AppKit
import CloudreveDesignSystem
import CloudreveDomainKit
import CloudreveProductKit

@MainActor
final class MenuBarIconTests: XCTestCase {
    /// Renders an image into a fixed @2x bitmap so frames can be compared pixel for pixel.
    private func pixels(_ image: NSImage) -> [UInt8] {
        let side = 36
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return Array(UnsafeBufferPointer(start: rep.bitmapData, count: side * side * 4))
    }

    func testStateGlyphsAreTheBundledTemplates() {
        let glyphs = [MenuBarIcon.upToDate, MenuBarIcon.paused, MenuBarIcon.attention, MenuBarIcon.syncingShell]
        for glyph in glyphs {
            XCTAssertTrue(glyph.isTemplate)
            XCTAssertEqual(glyph.size, MenuBarIcon.canvas, "every state keeps the status item's width")
            // The bundled PNGs, not the SF Symbol fallback.
            let widths = Set(glyph.representations.compactMap { ($0 as? NSBitmapImageRep)?.pixelsWide })
            XCTAssertTrue(widths.isSuperset(of: [22, 44]), "bundled reps: \(widths)")
        }
        let drawn = glyphs.map(pixels)
        XCTAssertEqual(Set(drawn).count, glyphs.count, "each state draws a different mark")
    }

    func testSyncingFramesKeepSizeAndTemplateAndMove() {
        let frames = MenuBarIcon.syncingFrames
        XCTAssertEqual(frames.count, MenuBarIcon.frameCount)
        for frame in frames {
            XCTAssertEqual(frame.size, MenuBarIcon.canvas, "the status item must not change width")
            XCTAssertTrue(frame.isTemplate)
        }
        XCTAssertEqual(pixels(frames[0]), pixels(MenuBarIcon.syncingShell), "a cycle starts from the bare cloud")
        XCTAssertNotEqual(pixels(frames[MenuBarIcon.frameCount / 4]), pixels(frames[MenuBarIcon.frameCount / 2]), "the arrow is drawn on")
        XCTAssertEqual(pixels(frames[MenuBarIcon.frameCount / 2]), pixels(MenuBarIcon.syncingStill), "the whole arrow shows mid-cycle")
        XCTAssertNotEqual(pixels(frames[MenuBarIcon.frameCount * 3 / 4]), pixels(MenuBarIcon.syncingStill), "then it is wiped away")
        writePreviewIfRequested(frames)
    }

    func testSyncingSpanDrawsOnHoldsThenWipesTailFirst() throws {
        XCTAssertNil(MenuBarIcon.visibleSpan(0))
        let early = try XCTUnwrap(MenuBarIcon.visibleSpan(0.2))
        XCTAssertEqual(early.lowerBound, 0)
        XCTAssertLessThan(early.upperBound, 1)
        XCTAssertEqual(MenuBarIcon.visibleSpan(0.5), 0...1)
        let late = try XCTUnwrap(MenuBarIcon.visibleSpan(0.8))
        XCTAssertGreaterThan(late.lowerBound, 0)
        XCTAssertEqual(late.upperBound, 1, "the head goes last")
    }

    func testAnimatorFollowsState() {
        let animator = MenuBarIconAnimator()
        XCTAssertNil(animator.state)
        XCTAssertTrue(animator.image === MenuBarIcon.syncingShell)

        animator.setState(.syncing)
        XCTAssertTrue(animator.isSyncing)
        XCTAssertEqual(animator.accessibilityLabel, "NimbusSync – Syncing")
        XCTAssertTrue(MenuBarIcon.syncingFrames.contains { $0 === animator.image } || animator.image === MenuBarIcon.syncingStill)

        for (state, still) in [(MenuBarIconState.upToDate, MenuBarIcon.upToDate), (.paused, MenuBarIcon.paused), (.attention, MenuBarIcon.attention)] {
            animator.setState(state)
            XCTAssertFalse(animator.isSyncing)
            XCTAssertTrue(animator.image === still, "\(state)")
            XCTAssertEqual(animator.accessibilityLabel, state.accessibilityLabel)
        }
    }

    func testIconStateRanksAttentionThenSyncingThenPaused() throws {
        let scope = try RemoteScope(origin: "https://cloudreve.example", accountID: "account", rootURI: CloudreveRemoteURI.canonical("/", accountID: "account"))
        func domain(_ status: DomainStatus) -> DomainDescriptor {
            var descriptor = DomainDescriptor(displayName: "d", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "s")
            descriptor.status = status
            return descriptor
        }
        func state(_ statuses: [DomainStatus], syncing: Bool = false, conflicts: Bool = false) -> MenuBarIconState {
            MenuBarIconState(domains: statuses.map(domain), isSyncing: syncing, hasActionableConflicts: conflicts)
        }
        XCTAssertEqual(state([]), .upToDate)
        XCTAssertEqual(state([.healthy, .eventDegraded]), .upToDate)
        XCTAssertEqual(state([.healthy], syncing: true), .syncing)
        XCTAssertEqual(state([.offline]), .paused)
        XCTAssertEqual(state([.offline, .healthy], syncing: true), .syncing, "another Domain is still syncing")
        XCTAssertEqual(state([.healthy], syncing: true, conflicts: true), .attention)
        XCTAssertEqual(state([.authExpired, .offline], syncing: true), .attention)
        XCTAssertEqual(state([.permanentError]), .attention)
    }

    func testSnapshotSyncingCoversTransfersAndRemoteWorkOnly() throws {
        let scope = try RemoteScope(origin: "https://cloudreve.example", accountID: "account", rootURI: CloudreveRemoteURI.canonical("/", accountID: "account"))
        func domain(_ status: DomainStatus) -> DomainDescriptor {
            var descriptor = DomainDescriptor(displayName: "d", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "s")
            descriptor.status = status
            return descriptor
        }
        XCTAssertFalse(ProductSnapshot(domains: [domain(.healthy)]).isSyncing)
        XCTAssertTrue(ProductSnapshot(domains: [domain(.healthy), domain(.reconciling)]).isSyncing)
        XCTAssertTrue(ProductSnapshot(domains: [domain(.syncing)]).isSyncing)
        XCTAssertFalse(ProductSnapshot(domains: [domain(.authExpired), domain(.offline)]).isSyncing)

        let running = ProductTask(domainIdentifier: "d", title: "a.txt", direction: .upload, state: .running)
        let done = ProductTask(domainIdentifier: "d", title: "b.txt", direction: .download, state: .succeeded)
        XCTAssertTrue(ProductSnapshot(domains: [domain(.healthy)], tasks: [running]).isSyncing)
        XCTAssertFalse(ProductSnapshot(domains: [domain(.healthy)], tasks: [done]).isSyncing)
    }

    func testStatusSummaryTooltipNamesOverallAndEveryDomain() throws {
        let scope = try RemoteScope(origin: "https://cloudreve.example", accountID: "account", rootURI: CloudreveRemoteURI.canonical("/", accountID: "account"))
        func domain(_ name: String, _ status: DomainStatus) -> DomainDescriptor {
            var descriptor = DomainDescriptor(displayName: name, scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "s")
            descriptor.status = status
            return descriptor
        }

        let empty = MenuBarStatusSummary(domains: [], activeTaskCount: 0, hasActionableConflicts: false)
        XCTAssertEqual(empty.tooltip, "NimbusSync — Ready to connect\nConnect a Cloudreve domain to get started.")

        let checking = MenuBarStatusSummary(domains: [domain("data@cloud", .reconciling)], activeTaskCount: 0, hasActionableConflicts: false)
        XCTAssertEqual(checking.tooltip, "NimbusSync — Checking for updates\ndata@cloud: Checking for updates")

        let busy = MenuBarStatusSummary(domains: [domain("data@cloud", .healthy)], activeTaskCount: 2, hasActionableConflicts: true)
        XCTAssertEqual(busy.headline, "Syncing your files")
        XCTAssertEqual(busy.tooltip, "NimbusSync — Syncing your files\ndata@cloud: Up to date\n2 transfers in progress\nConflicts need review")

        let attention = MenuBarStatusSummary(domains: [domain("a", .healthy), domain("b", .authExpired)], activeTaskCount: 1, hasActionableConflicts: false)
        XCTAssertEqual(attention.headline, "Needs your attention", "a problem outranks an active transfer")
        XCTAssertEqual(attention.detail, "1 domain need a review.")
        XCTAssertTrue(attention.tooltip.contains("b: Authorization required"))

        let many = MenuBarStatusSummary(domains: (1...7).map { domain("d\($0)", .healthy) }, activeTaskCount: 0, hasActionableConflicts: false)
        XCTAssertTrue(many.tooltip.hasSuffix("d5: Up to date\nand 2 more"))
    }

    func testAnimatorKeepsTheLatestTooltip() {
        let animator = MenuBarIconAnimator()
        animator.setTooltip("NimbusSync — Up to date")
        XCTAssertEqual(animator.tooltip, "NimbusSync — Up to date")
    }

    /// `NIMBUSSYNC_ICON_PREVIEW=/path/preview.png swift test --filter MenuBarIconTests` writes an
    /// enlarged contact sheet (each still state + every syncing frame, light and dark bar) for a visual check.
    private func writePreviewIfRequested(_ frames: [NSImage]) {
        guard let path = ProcessInfo.processInfo.environment["NIMBUSSYNC_ICON_PREVIEW"] else { return }
        let images = [MenuBarIcon.upToDate, MenuBarIcon.paused, MenuBarIcon.attention, MenuBarIcon.syncingStill] + frames
        let zoom: CGFloat = 8, cellWidth = MenuBarIcon.canvas.width * zoom + 16, cell = MenuBarIcon.canvas.height * zoom + 16
        let sheet = NSImage(size: NSSize(width: cellWidth * CGFloat(images.count), height: cell * 2), flipped: false) { _ in
            for (row, (background, ink)) in [(NSColor(white: 0.93, alpha: 1), NSColor.black), (NSColor(white: 0.17, alpha: 1), NSColor.white)].enumerated() {
                background.setFill()
                NSRect(x: 0, y: CGFloat(1 - row) * cell, width: cellWidth * CGFloat(images.count), height: cell).fill()
                for (index, image) in images.enumerated() {
                    let rect = NSRect(x: CGFloat(index) * cellWidth + 8, y: CGFloat(1 - row) * cell + 8, width: MenuBarIcon.canvas.width * zoom, height: MenuBarIcon.canvas.height * zoom)
                    // Rasterise at @2x exactly as a Retina menu bar would, then enlarge without
                    // smoothing, so the sheet shows the real pixels rather than a vector re-render.
                    let pixelsWide = Int(MenuBarIcon.canvas.width * 2), pixelsHigh = Int(MenuBarIcon.canvas.height * 2)
                    let retina = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: pixelsWide * 4, bitsPerPixel: 32)!
                    retina.size = MenuBarIcon.canvas
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: retina)
                    image.draw(in: NSRect(origin: .zero, size: MenuBarIcon.canvas))
                    ink.set()
                    NSRect(origin: .zero, size: MenuBarIcon.canvas).fill(using: .sourceAtop)
                    NSGraphicsContext.restoreGraphicsState()
                    NSGraphicsContext.current?.imageInterpolation = .none
                    retina.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
                }
            }
            return true
        }
        guard let tiff = sheet.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
