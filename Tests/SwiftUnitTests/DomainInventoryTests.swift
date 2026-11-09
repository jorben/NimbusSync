import XCTest
import Foundation
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveAuthKit
import CloudreveDomainService

/// The startup inventory says why a Domain is unmanaged in fixed, redacted words.
final class DomainInventoryTests: XCTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        for url in cleanup {
            try? FileManager.default.removeItem(at: url)
            for suffix in ["-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        cleanup.removeAll()
        super.tearDown()
    }

    private func makeRegistry() throws -> SQLiteStateStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-inventory-\(UUID().uuidString).sqlite3")
        cleanup.append(url)
        return try SQLiteStateStore(url: url)
    }

    func testInvalidityReasonNamesThePartThatIsWrong() {
        XCTAssertNil(RemoteScope.invalidityReason(origin: "https://cloud.example.com", accountID: "account", rootURI: "/"))
        XCTAssertEqual(RemoteScope.invalidityReason(origin: "http://cloud.example.com", accountID: "account", rootURI: "/"), "origin_not_https")
        XCTAssertEqual(RemoteScope.invalidityReason(origin: "https://cloud.example.com", accountID: "", rootURI: "/"), "account")
        XCTAssertEqual(RemoteScope.invalidityReason(origin: "not a url", accountID: "account", rootURI: "/"), "origin_unparsable")
        let rootReason = RemoteScope.invalidityReason(origin: "https://cloud.example.com", accountID: "account", rootURI: "cloudreve://trash/secret-folder")
        XCTAssertTrue(rootReason?.hasPrefix("root_uri:") == true)
        XCTAssertFalse(rootReason?.contains("secret-folder") == true, "the reason never carries path names")
    }

    func testCleanupSummaryListsIdentifiersAndFailures() {
        var report = OrphanedDomainCleanupReport(outcome: .checked, registryIdentifiers: ["crd-b"], systemIdentifiers: ["crd-b", "crd-a"])
        report.failed.append(("crd-a", "NSFileProviderErrorDomain:-2001"))
        XCTAssertEqual(report.summary, "outcome=checked failed=crd-a:NSFileProviderErrorDomain:-2001 system_only=crd-a registry=crd-b system=crd-a,crd-b")
        XCTAssertEqual(OrphanedDomainCleanupReport(outcome: .registryEmpty, registryIdentifiers: [], systemIdentifiers: []).summary, "outcome=registry_empty registry= system=")
        XCTAssertEqual(OrphanedDomainCleanupReport(outcome: .registryEmpty, registryIdentifiers: [], systemIdentifiers: ["crd-a"]).summary, "outcome=registry_empty system_only=crd-a registry= system=crd-a")
    }

    func testCleanupSummaryMarksUncollectedListsUnknown() {
        XCTAssertEqual(OrphanedDomainCleanupReport(outcome: .registryUnreadable).summary, "outcome=registry_unreadable registry=? system=?")
        let listingFailed = OrphanedDomainCleanupReport(outcome: .systemListingFailed, registryIdentifiers: ["crd-a"], error: "NSFileProviderErrorDomain:-2001")
        XCTAssertEqual(listingFailed.summary, "outcome=system_listing_failed error=NSFileProviderErrorDomain:-2001 registry=crd-a system=?")
    }

    func testCleanupSummaryKeepsFailuresWithinActivityLogLimit() {
        let identifiers = (0..<8).map { _ in CloudreveIdentifier.domain() }
        let orphan = CloudreveIdentifier.domain()
        var report = OrphanedDomainCleanupReport(outcome: .checked, registryIdentifiers: identifiers, systemIdentifiers: identifiers + [orphan])
        report.failed.append((orphan, "NSFileProviderErrorDomain:-2001"))
        let summary = report.summary
        XCTAssertGreaterThan(summary.count, 600, "the lists alone outgrow the activity log limit")
        XCTAssertTrue(summary.prefix(600).contains("failed=\(orphan):NSFileProviderErrorDomain:-2001"))
        XCTAssertTrue(summary.prefix(600).contains("system_only=\(orphan)"))
    }

    func testUnreadableDomainsIsEmptyForValidOrEmptyRegistry() async throws {
        let registry = try makeRegistry()
        let service = DomainRegistryService(store: registry, vault: MemoryCredentialVault())
        let emptyRows = await service.unreadableDomains()
        XCTAssertTrue(emptyRows.isEmpty)
        let scope = try RemoteScope(origin: "https://cloud.example.com", accountID: "account", rootURI: "/")
        try registry.registerDomain(DomainDescriptor(identifier: CloudreveIdentifier.domain(), displayName: "Inventory", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential", capabilitySnapshot: .cloudreveV4(serverVersion: "4.0.0")))
        let validRows = await service.unreadableDomains()
        XCTAssertTrue(validRows.isEmpty)
    }
}
