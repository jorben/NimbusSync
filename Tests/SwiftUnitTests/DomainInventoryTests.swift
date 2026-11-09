import XCTest
import Foundation
import CloudreveDomainKit
import CloudreveDomainService

/// The startup inventory says why a Domain is unmanaged in fixed, redacted words.
final class DomainInventoryTests: XCTestCase {
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
        XCTAssertEqual(report.summary, "outcome=checked registry=crd-b system=crd-a,crd-b failed=crd-a:NSFileProviderErrorDomain:-2001")
        XCTAssertEqual(OrphanedDomainCleanupReport(outcome: .registryEmpty).summary, "outcome=registry_empty registry= system=")
    }
}
