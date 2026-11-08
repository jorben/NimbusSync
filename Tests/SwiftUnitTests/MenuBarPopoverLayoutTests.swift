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
        XCTAssertLessThanOrEqual(height, 620, "the popover stays bounded and scrolls beyond that")
    }

    func testEmptyPopoverStillShowsItsFirstRunState() {
        XCTAssertGreaterThan(fittingHeight(MenuBarPopoverView(domains: [])), 220)
    }

    func testLongContentIsBoundedAndScrolls() throws {
        let scope = try RemoteScope(origin: "https://cloud.example.com", accountID: "account", rootURI: "cloudreve://my/")
        let domains = (0..<30).map { index in
            DomainDescriptor(identifier: "crd-\(String(format: "%08d", index))-6666-4666-8666-666666666666", displayName: "Domain \(index)", scope: scope, rootRemoteID: "root\(index)", accountID: "account", secretReference: "ref")
        }
        XCTAssertLessThanOrEqual(fittingHeight(MenuBarPopoverView(domains: domains)), 620)
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
