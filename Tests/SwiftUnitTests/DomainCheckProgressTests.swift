import XCTest
import Foundation
import CloudreveDesignSystem
import CloudreveDomainKit
import CloudreveStoreBridge

final class DomainCheckProgressTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testEstimateUsesThePreviousItemCountAndNeverClaimsCompletion() {
        XCTAssertEqual(DomainCheckProgress(phase: .scanningFiles, scannedItems: 250, expectedItems: 1_000, startedAt: start).estimatedFraction, 0.25)
        XCTAssertEqual(DomainCheckProgress(phase: .scanningFiles, scannedItems: 1_500, expectedItems: 1_000, startedAt: start).estimatedFraction, 0.99, "more items than last time stays short of done")
        XCTAssertEqual(DomainCheckProgress(phase: .applyingDeletions, scannedItems: 10, expectedItems: 1_000, startedAt: start).estimatedFraction, 0.99)
        XCTAssertNil(DomainCheckProgress(phase: .scanningFiles, scannedItems: 250, expectedItems: 0, startedAt: start).estimatedFraction, "a first check has nothing to estimate against")
    }

    func testYoungChecksAreNotShown() {
        let progress = DomainCheckProgress(phase: .scanningFiles, scannedItems: 0, expectedItems: 10, startedAt: start)
        XCTAssertFalse(progress.isWorthShowing(at: start.addingTimeInterval(1)))
        XCTAssertTrue(progress.isWorthShowing(at: start.addingTimeInterval(2)))
    }

    func testVisibleProgressRequiresACheckingDomain() throws {
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "cloudreve://my/")
        var domain = DomainDescriptor(identifier: "crd-33333333-3333-4333-8333-333333333333", displayName: "Progress", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "ref")
        let progress = [domain.identifier: DomainCheckProgress(phase: .scanningFiles, scannedItems: 5, expectedItems: 10, startedAt: start)]
        domain.status = .healthy
        XCTAssertNil(DomainCheckProgress.visible(for: domain, in: progress, at: start.addingTimeInterval(10)), "a leftover run from a crashed check must not show")
        domain.status = .reconciling
        XCTAssertNotNil(DomainCheckProgress.visible(for: domain, in: progress, at: start.addingTimeInterval(10)))
    }

    func testSummaryDescribesPhaseCountsAndPercent() {
        XCTAssertEqual(DomainCheckProgressView.summary(DomainCheckProgress(phase: .scanningFiles, scannedItems: 1_234, expectedItems: 5_600, startedAt: start)), "Checking files · \(1_234.formatted()) of ~\(5_600.formatted()) · 22%")
        XCTAssertEqual(DomainCheckProgressView.summary(DomainCheckProgress(phase: .scanningFiles, scannedItems: 42, expectedItems: 0, startedAt: start)), "Checking files · 42 items")
        XCTAssertEqual(DomainCheckProgressView.summary(DomainCheckProgress(phase: .applyingDeletions, scannedItems: 42, expectedItems: 50, startedAt: start)), "Finishing up · 99%")
    }

    func testStoreRecordsProgressOnlyForActiveRuns() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-progress-\(UUID().uuidString).sqlite3")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let store = try SQLiteStateStore(url: url)
        XCTAssertNil(try store.activeCheckProgress())

        let runID = UUID()
        try store.startReconcile(runID: runID, scope: "cloudreve://my", generation: 1, phase: "prepared", cursor: nil)
        XCTAssertNil(try store.activeCheckProgress(), "a run that has not started scanning reports nothing")
        try store.updateReconcile(runID: runID, phase: "scanning_normal", cursor: "page:2", state: "active", progress: (scanned: 500, expected: 2_000))
        var progress = try XCTUnwrap(store.activeCheckProgress())
        XCTAssertEqual(progress.phase, .scanningFiles)
        XCTAssertEqual(progress.scannedItems, 500)
        XCTAssertEqual(progress.expectedItems, 2_000)

        try store.updateReconcile(runID: runID, phase: "scanning_normal", cursor: "page:3", state: "active")
        XCTAssertEqual(try store.activeCheckProgress()?.scannedItems, 500, "a write without progress leaves it as it was")
        try store.updateReconcileProgress(runID: runID, phase: "scanning_trash", scanned: 1_900, expected: 2_000)
        progress = try XCTUnwrap(store.activeCheckProgress())
        XCTAssertEqual(progress.phase, .scanningTrash)
        XCTAssertEqual(progress.scannedItems, 1_900)
        XCTAssertEqual(try store.activeReconcileRuns().first?.cursor, "page:3", "moving phase keeps the resumable cursor")

        try store.updateReconcile(runID: runID, phase: "completed", cursor: nil, state: "completed")
        XCTAssertNil(try store.activeCheckProgress())
    }
}
