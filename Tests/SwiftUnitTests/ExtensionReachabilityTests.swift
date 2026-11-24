import XCTest
import FileProvider
@testable import CloudreveDomainKit
import CloudreveDesignSystem

@MainActor
final class ExtensionReachabilityTests: EnglishLocalizationTestCase {
    private let embedded = "/Applications/NimbusSync.app/Contents/PlugIns/NimbusSyncFileProvider.appex"

    private func domain(_ name: String, _ status: DomainStatus) throws -> DomainDescriptor {
        let scope = try RemoteScope(origin: "https://cloudreve.example", accountID: "account", rootURI: CloudreveRemoteURI.canonical("/", accountID: "account"))
        var descriptor = DomainDescriptor(displayName: name, scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "s")
        descriptor.status = status
        return descriptor
    }

    func testOneFailureCanBeASlowLaunchButTwoMakeTheExtensionUnavailable() {
        var tracker = ExtensionReachabilityTracker()
        XCTAssertNil(tracker.unavailableReason)
        XCTAssertEqual(tracker.nextProbeInterval, ExtensionReachabilityTracker.healthyInterval)

        tracker.record(.failed(stage: "service", domain: NSCocoaErrorDomain, code: 4099), expectedBundlePath: embedded)
        XCTAssertNil(tracker.unavailableReason, "a single failure may be a slow first launch")
        XCTAssertEqual(tracker.nextProbeInterval, ExtensionReachabilityTracker.failingInterval, "retry soon")

        tracker.record(.timedOut, expectedBundlePath: embedded)
        XCTAssertEqual(tracker.unavailableReason, .notResponding)

        tracker.record(.answered(bundlePath: embedded, version: "0.1.3"), expectedBundlePath: embedded)
        XCTAssertNil(tracker.unavailableReason, "one answer clears it")
        XCTAssertEqual(tracker.consecutiveFailures, 0)
    }

    func testMissingProbeServiceCountsAsFailure() {
        var tracker = ExtensionReachabilityTracker()
        tracker.record(.serviceMissing, expectedBundlePath: embedded)
        tracker.record(.serviceMissing, expectedBundlePath: embedded)
        XCTAssertEqual(tracker.unavailableReason, .notResponding)
    }

    func testAnswerFromAnotherCopyIsConclusiveAtOnce() {
        var tracker = ExtensionReachabilityTracker()
        tracker.record(.answered(bundlePath: "/private/tmp/ci/NimbusSync.app/Contents/PlugIns/NimbusSyncFileProvider.appex", version: "0.2.0"), expectedBundlePath: embedded)
        XCTAssertEqual(tracker.unavailableReason, .staleCopy)
    }

    func testSamePathThroughASymlinkIsNotAStaleCopy() throws {
        let name = "nimbussync-probe-\(UUID().uuidString).appex"
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(ExtensionReachabilityTracker.samePath("/tmp/x/../\(name)", "/private/tmp/\(name)"))
        XCTAssertFalse(ExtensionReachabilityTracker.samePath("/tmp/\(name)", "/tmp/other.appex"))
        var tracker = ExtensionReachabilityTracker()
        tracker.record(.answered(bundlePath: "/tmp/\(name)", version: "1"), expectedBundlePath: "/private/tmp/\(name)")
        XCTAssertNil(tracker.unavailableReason)
        tracker.record(.answered(bundlePath: "/anywhere.appex", version: "1"), expectedBundlePath: nil)
        XCTAssertNil(tracker.unavailableReason, "without an embedded extension to compare, any answer is fine")
    }

    func testDisabledDomainIsNotAnExtensionFailure() {
        XCTAssertEqual(ExtensionProbeResult.classify(NSError(domain: NSFileProviderErrorDomain, code: -2011), stage: "service"), .domainDisabled)
        XCTAssertEqual(ExtensionProbeResult.classify(NSError(domain: "NSFileProviderInternalErrorDomain", code: 12), stage: "service"), .domainDisabled)
        XCTAssertEqual(ExtensionProbeResult.classify(NSError(domain: NSCocoaErrorDomain, code: 4099), stage: "connection"), .failed(stage: "connection", domain: NSCocoaErrorDomain, code: 4099))

        var tracker = ExtensionReachabilityTracker()
        tracker.record(.timedOut, expectedBundlePath: nil)
        tracker.record(.timedOut, expectedBundlePath: nil)
        tracker.record(.domainDisabled, expectedBundlePath: nil)
        XCTAssertNil(tracker.unavailableReason, "Finder integration reports a switched-off Domain")
    }

    func testOverlayMarksUnavailableDomainsButKeepsRemovalStates() throws {
        let healthy = try domain("a", .healthy)
        let expired = try domain("b", .authExpired)
        let removing = try domain("c", .preservedRemoval)
        let untouched = try domain("d", .healthy)
        let shown = ExtensionReachability.overlay([healthy, expired, removing, untouched], unavailable: [healthy.identifier, expired.identifier, removing.identifier])
        XCTAssertEqual(shown.map(\.status), [.extensionUnavailable, .extensionUnavailable, .preservedRemoval, .healthy])
        XCTAssertEqual(ExtensionReachability.overlay([healthy], unavailable: []), [healthy])
    }

    func testUnavailableExtensionNeedsAttentionEverywhere() throws {
        let domains = [try domain("data@cloud", .extensionUnavailable), try domain("other", .healthy)]
        XCTAssertEqual(MenuBarIconState(domains: domains, isSyncing: true, hasActionableConflicts: false), .attention)
        let summary = MenuBarStatusSummary(domains: domains, activeTaskCount: 0, hasActionableConflicts: false)
        XCTAssertEqual(summary.headline, "Needs your attention")
        XCTAssertTrue(summary.tooltip.contains("data@cloud: Finder extension unavailable"))
        XCTAssertEqual(SettingsDomainsSummary(domains: domains).needsAttention, 1)
    }

    func testIssueTextIsLocalized() {
        XCTAssertEqual(L10n.text(ExtensionIssueText.title, language: .simplifiedChinese), "Finder 无法载入你的文件")
        for reason in [ExtensionUnavailableReason.notResponding, .staleCopy] {
            let detail = ExtensionIssueText.detail(reason)
            XCTAssertNotEqual(L10n.text(detail, language: .simplifiedChinese), detail, "\(reason) has a translation")
        }
    }
}
