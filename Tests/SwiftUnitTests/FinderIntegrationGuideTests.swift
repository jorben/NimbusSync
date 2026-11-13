import XCTest
import AppKit
import SwiftUI
import CloudreveDesignSystem
import CloudreveDomainKit

/// Finder integration switched off in System Settings stops every sync, so the app must say so
/// on its own: a paused menu bar glyph, a banner, a Settings card and a guide that offers itself.
@MainActor
final class FinderIntegrationGuideTests: XCTestCase {
    private func domain(_ status: DomainStatus) throws -> DomainDescriptor {
        let scope = try RemoteScope(origin: "https://cloudreve.example", accountID: "account", rootURI: CloudreveRemoteURI.canonical("/", accountID: "account"))
        var descriptor = DomainDescriptor(displayName: "data@cloud", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "s")
        descriptor.status = status
        return descriptor
    }

    func testFinderIntegrationOffPausesTheMenuBarIconAboveEveryOtherState() throws {
        XCTAssertEqual(MenuBarIconState(domains: [try domain(.healthy)], isSyncing: false, hasActionableConflicts: false, finderIntegrationOff: true), .paused)
        XCTAssertEqual(MenuBarIconState(domains: [try domain(.syncing)], isSyncing: true, hasActionableConflicts: false, finderIntegrationOff: true), .paused, "nothing actually syncs while it is off")
        XCTAssertEqual(MenuBarIconState(domains: [try domain(.authExpired)], isSyncing: false, hasActionableConflicts: true, finderIntegrationOff: true), .paused)
        XCTAssertEqual(MenuBarIconState(domains: [try domain(.healthy)], isSyncing: false, hasActionableConflicts: false), .upToDate, "on by default")
    }

    func testSummaryExplainsWhySyncingIsPaused() throws {
        let summary = MenuBarStatusSummary(domains: [try domain(.healthy)], activeTaskCount: 2, hasActionableConflicts: true, finderIntegrationOff: true)
        XCTAssertEqual(summary.headline, FinderIntegrationGuideText.offHeadline)
        XCTAssertEqual(summary.subtitle, FinderIntegrationGuideText.offSubtitle)
        XCTAssertTrue(summary.tooltip.hasPrefix("NimbusSync — Finder integration is off\n"))
        XCTAssertTrue(summary.tooltip.contains("2 transfers in progress"))
        let normal = MenuBarStatusSummary(domains: [try domain(.healthy)], activeTaskCount: 0, hasActionableConflicts: false)
        XCTAssertEqual(normal.subtitle, "Up to date")
    }

    func testGuideOffersItselfOnlyWhileOffOncePerRunAndDaily() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        for state in [FinderIntegrationState.unknown, .notSetUp, .on] {
            XCTAssertFalse(FinderIntegrationPromptPolicy.shouldPrompt(state: state, alreadyPromptedThisRun: false, lastPromptedAt: nil, now: now), "\(state)")
        }
        XCTAssertTrue(FinderIntegrationPromptPolicy.shouldPrompt(state: .off, alreadyPromptedThisRun: false, lastPromptedAt: nil, now: now))
        XCTAssertFalse(FinderIntegrationPromptPolicy.shouldPrompt(state: .off, alreadyPromptedThisRun: true, lastPromptedAt: nil, now: now))
        XCTAssertFalse(FinderIntegrationPromptPolicy.shouldPrompt(state: .off, alreadyPromptedThisRun: false, lastPromptedAt: now.addingTimeInterval(-3600), now: now), "not again within a day")
        XCTAssertTrue(FinderIntegrationPromptPolicy.shouldPrompt(state: .off, alreadyPromptedThisRun: false, lastPromptedAt: now.addingTimeInterval(-FinderIntegrationPromptPolicy.interval), now: now))
    }

    func testPromptTimeRoundTripsThroughDefaults() throws {
        let suite = "FinderIntegrationGuideTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(FinderIntegrationPromptPolicy.lastPrompted(in: defaults))
        let date = Date(timeIntervalSince1970: 1_234_567)
        FinderIntegrationPromptPolicy.recordPrompt(at: date, in: defaults)
        XCTAssertEqual(FinderIntegrationPromptPolicy.lastPrompted(in: defaults), date)
    }

    func testSettingsPathFollowsTheMacOSVersion() {
        XCTAssertEqual(FinderIntegrationGuideText.settingsPath(majorVersion: 15), "General › Login Items & Extensions › File Providers")
        XCTAssertEqual(FinderIntegrationGuideText.settingsPath(majorVersion: 26), "General › Login Items & Extensions › File Providers")
        XCTAssertEqual(FinderIntegrationGuideText.settingsPath(majorVersion: 14), "Privacy & Security › Extensions › File Providers")
        XCTAssertEqual(FinderIntegrationGuideText.steps(majorVersion: 15).count, 3)
        XCTAssertEqual(FinderIntegrationGuideText.steps(majorVersion: 13).count, 3)
    }

    /// Without the bundled art the guide would fall back to a bare symbol.
    func testIllustrationsAreBundledForBothAppearances() throws {
        for image in [FinderIntegrationIllustration.light, FinderIntegrationIllustration.dark] {
            let art = try XCTUnwrap(image)
            let widths = Set(art.representations.map(\.pixelsWide))
            XCTAssertTrue(widths.isSuperset(of: [400, 800]), "1x and 2x bitmaps: \(widths)")
        }
    }

    func testPopoverShowsTheBannerWithoutLosingItsLayout() throws {
        let off = fittingHeight(MenuBarPopoverView(domains: [try domain(.healthy)], finderIntegrationOff: true))
        let on = fittingHeight(MenuBarPopoverView(domains: [try domain(.healthy)]))
        XCTAssertGreaterThan(off, on + 40, "the banner adds a row")
        XCTAssertLessThanOrEqual(off, 660)
    }

    func testGuideWindowAndSettingsCardLayOut() {
        let guide = NSHostingController(rootView: FinderIntegrationGuideView(onOpenSettings: {}, onLater: {}))
        let size = guide.sizeThatFits(in: NSSize(width: 520, height: 2000))
        XCTAssertEqual(size.width, 520, accuracy: 1)
        XCTAssertGreaterThan(size.height, 450)
        XCTAssertLessThan(size.height, 800, "fits a small screen")
        writePreviewIfRequested(guide.view, size: size, name: "guide")

        let card = NSHostingController(rootView: FinderIntegrationGuideCard(onOpenSettings: {}, onCheckAgain: {}).frame(width: 680))
        let cardSize = card.sizeThatFits(in: NSSize(width: 680, height: 2000))
        XCTAssertGreaterThan(cardSize.height, 150)
        writePreviewIfRequested(card.view, size: cardSize, name: "card")
    }

    private func fittingHeight(_ view: MenuBarPopoverView) -> CGFloat {
        let controller = NSHostingController(rootView: view.frame(width: 380))
        controller.view.frame = NSRect(x: 0, y: 0, width: 380, height: 100)
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        controller.view.layoutSubtreeIfNeeded()
        return controller.sizeThatFits(in: NSSize(width: 380, height: 0)).height
    }

    /// `NIMBUSSYNC_GUIDE_PREVIEW=/tmp/dir swift test --filter FinderIntegrationGuideTests` writes
    /// light and dark renders of the guide window and the Settings card for a visual check.
    private func writePreviewIfRequested(_ view: NSView, size: NSSize, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["NIMBUSSYNC_GUIDE_PREVIEW"] else { return }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            window.backgroundColor = appearance == .aqua ? .windowBackgroundColor : NSColor(white: 0.16, alpha: 1)
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
}
