import XCTest
import AppKit
import SwiftUI
import CloudreveDesignSystem
import CloudreveDomainKit

/// The menu bar window sizes itself to the popover's ideal size. A bare ScrollView has almost no
/// ideal height, so the domain list, tasks and log collapsed away and only the header and footer
/// showed.
@MainActor
final class MenuBarPopoverLayoutTests: XCTestCase {
    func testPopoverSizesToShowItsDomains() throws {
        let scope = try RemoteScope(origin: "https://cloud.example.com", accountID: "account", rootURI: "cloudreve://my/")
        var domains: [DomainDescriptor] = []
        for index in 0..<2 {
            var domain = DomainDescriptor(identifier: "crd-5555555\(index)-5555-4555-8555-555555555555", displayName: "Domain \(index)", scope: scope, rootRemoteID: "root\(index)", accountID: "account", secretReference: "ref")
            domain.status = .healthy
            domains.append(domain)
        }
        let height = fittingHeight(MenuBarPopoverView(domains: domains, onCheckDomain: { _ in }))
        XCTAssertGreaterThan(height, 240, "header, status overview and two domain rows must all fit")
        XCTAssertLessThanOrEqual(height, 660, "the popover stays bounded and scrolls beyond that")
    }

    func testEmptyPopoverStillShowsItsFirstRunState() {
        XCTAssertGreaterThan(fittingHeight(MenuBarPopoverView(domains: [])), 220)
    }

    func testLongContentIsBoundedAndScrolls() throws {
        let scope = try RemoteScope(origin: "https://cloud.example.com", accountID: "account", rootURI: "cloudreve://my/")
        let domains = (0..<30).map { index in
            DomainDescriptor(identifier: "crd-\(String(format: "%08d", index))-6666-4666-8666-666666666666", displayName: "Domain \(index)", scope: scope, rootRemoteID: "root\(index)", accountID: "account", secretReference: "ref")
        }
        // Header, a 500 pt scroll area and the footer.
        XCTAssertLessThanOrEqual(fittingHeight(MenuBarPopoverView(domains: domains, onQuit: {})), 660)
    }

    /// The height the popover settles on when the window asks for the smallest size it accepts,
    /// which is what the menu bar window does.
    private func fittingHeight(_ view: MenuBarPopoverView) -> CGFloat {
        let controller = NSHostingController(rootView: view.frame(width: 380))
        controller.view.frame = NSRect(x: 0, y: 0, width: 380, height: 100)
        controller.view.layoutSubtreeIfNeeded()
        // The content height is measured during layout and applied on the next pass.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        controller.view.layoutSubtreeIfNeeded()
        return controller.sizeThatFits(in: NSSize(width: 380, height: 0)).height
    }
}

final class DomainIconTests: XCTestCase {
    /// Without the bundled bitmaps every Domain would silently fall back to a generic drive glyph.
    @MainActor
    func testDomainIconIsTheBundledCloudreveLogo() throws {
        let logo = try XCTUnwrap(DomainIconView.logo)
        XCTAssertEqual(logo.size, NSSize(width: 48, height: 48))
        let pixelWidths = Set(logo.representations.map(\.pixelsWide))
        XCTAssertTrue(pixelWidths.isSuperset(of: [48, 96, 144]), "1x, 2x and 3x bitmaps: \(pixelWidths)")
    }
}

final class TaskDisplayCaptionTests: EnglishLocalizationTestCase {
    func testCaptionShowsTimeTodayAndDateOtherwise() {
        let now = Date()
        let today = TaskDisplay(id: UUID(), title: "a.txt", progress: nil, detail: "succeeded", state: "succeeded", date: now)
        XCTAssertEqual(today.caption(relativeTo: now), "\(now.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale))) · succeeded")
        let earlier = now.addingTimeInterval(-3 * 24 * 3600)
        XCTAssertEqual(TaskDisplay.caption(detail: "failed", date: earlier, relativeTo: now), "\(earlier.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))) · failed")
        XCTAssertEqual(TaskDisplay.caption(detail: "queued", date: nil, relativeTo: now), "queued")
    }
}

/// The popover's header line, issue rows and check progress read these, so their words stay stable.
final class MenuBarPopoverTextTests: EnglishLocalizationTestCase {
    private func domain(_ index: Int, status: DomainStatus) throws -> DomainDescriptor {
        let scope = try RemoteScope(origin: "https://cloud.example.com", accountID: "account", rootURI: "cloudreve://my/")
        var domain = DomainDescriptor(identifier: "crd-7777777\(index)-7777-4777-8777-777777777777", displayName: "Domain \(index)", scope: scope, rootRemoteID: "root\(index)", accountID: "account", secretReference: "ref")
        domain.status = status
        return domain
    }

    func testHeaderSubtitleCountsBusyAndHealthyDomains() throws {
        let syncing = MenuBarStatusSummary(domains: [try domain(0, status: .reconciling), try domain(1, status: .healthy)], activeTaskCount: 0, hasActionableConflicts: false)
        XCTAssertEqual(syncing.subtitle, "Syncing 1 of 2 domains")
        let healthy = MenuBarStatusSummary(domains: [try domain(0, status: .healthy), try domain(1, status: .healthy)], activeTaskCount: 0, hasActionableConflicts: false)
        XCTAssertEqual(healthy.subtitle, "All 2 domains up to date")
        let attention = MenuBarStatusSummary(domains: [try domain(0, status: .authExpired), try domain(1, status: .syncing)], activeTaskCount: 3, hasActionableConflicts: false)
        XCTAssertEqual(attention.subtitle, "1 of 2 domains needs attention")
        XCTAssertEqual(MenuBarStatusSummary(domains: [], activeTaskCount: 0, hasActionableConflicts: false).subtitle, "No domains connected")
    }

    func testIssueRowsExplainTheirFailureInWords() {
        let now = Date()
        let task = TaskDisplay(id: UUID(), title: "Q3.pdf", progress: nil, detail: "permission_denied", state: "failed", date: now.addingTimeInterval(-10), domainName: "data@cloud")
        XCTAssertTrue(task.isIssue)
        XCTAssertTrue(task.canRetry)
        XCTAssertEqual(task.activityCaption(relativeTo: now), "data@cloud · Permission denied · Just now")
        XCTAssertEqual(TaskDisplay.reason(for: "some_new_code"), "Some new code")
        XCTAssertFalse(TaskDisplay(id: UUID(), title: "a", progress: nil, detail: "succeeded", state: "succeeded").isIssue)
    }

    func testFileKindFollowsTheExtension() {
        XCTAssertEqual(FileKindIcon(fileName: "Q3-Financial-Report.PDF"), .pdf)
        XCTAssertEqual(FileKindIcon(fileName: "IMG_4821.HEIC"), .image)
        XCTAssertEqual(FileKindIcon(fileName: "Product-Demo-v2.mp4"), .video)
        XCTAssertEqual(FileKindIcon(fileName: "Inventory-Nov.xlsx"), .spreadsheet)
        XCTAssertEqual(FileKindIcon(fileName: "crd-item-without-extension"), .generic)
    }

    func testCheckProgressShowsCountsPercentAndTimeLeft() {
        let now = Date()
        let progress = DomainCheckProgress(phase: .scanningFiles, scannedItems: 60_000, expectedItems: 150_000, startedAt: now.addingTimeInterval(-120), updatedAt: now)
        XCTAssertEqual(PopoverCheckProgressText.activity(progress), "Checking files — \(60_000.formatted()) of about \(150_000.formatted())")
        // 40% done after two minutes leaves three.
        XCTAssertEqual(PopoverCheckProgressText.estimate(progress, now: now), "40% · about 3 min left")

        let young = DomainCheckProgress(phase: .scanningFiles, scannedItems: 600, expectedItems: 1_500, startedAt: now.addingTimeInterval(-3), updatedAt: now)
        XCTAssertEqual(PopoverCheckProgressText.estimate(young, now: now), "40%", "too early for a time estimate")

        let first = DomainCheckProgress(phase: .scanningFiles, scannedItems: 42, expectedItems: 0, startedAt: now.addingTimeInterval(-30), updatedAt: now)
        XCTAssertEqual(PopoverCheckProgressText.activity(first), "Checking files — 42 items")
        XCTAssertNil(PopoverCheckProgressText.estimate(first, now: now))
    }
}
