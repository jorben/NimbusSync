import XCTest
import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudreveDomainKit
import CloudreveStoreBridge

/// A real account (~136k files + ~14k folders after a Nextcloud migration)
/// exceeded the former 100k domain bound, so every full reconcile failed with
/// `normal_scan_bound` and restarted on the next stream reconnect.
final class DomainScaleTests: XCTestCase {
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

    private func makeStore() throws -> SQLiteStateStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-scale-\(UUID().uuidString).sqlite3")
        cleanup.append(url)
        return try SQLiteStateStore(url: url)
    }

    private func item(_ name: String, remoteID: String?, tombstone: Bool = false) -> RemoteItem {
        RemoteItem(
            remoteID: remoteID,
            parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
            name: name,
            uri: "cloudreve://account@my/\(name)",
            kind: .file,
            contentType: UTType.data.identifier,
            version: ItemVersion(content: Data(name.utf8), metadata: Data(name.utf8)),
            tombstone: tombstone
        )
    }

    func testDomainBoundCoversObservedAccountSize() {
        XCTAssertGreaterThanOrEqual(DomainScale.maximumItems, 1_000_000)
    }

    func testRemoteIdentitiesListOnlyLiveRemoteItems() throws {
        let store = try makeStore()
        let live = item("live.txt", remoteID: "r-live")
        let local = item("local-only.txt", remoteID: nil)
        let deleted = item("deleted.txt", remoteID: "r-deleted", tombstone: true)
        try store.insertItems([live, local, deleted])

        let identities = try store.remoteIdentities()
        XCTAssertEqual(identities, [StoredRemoteIdentity(itemIdentifier: live.itemIdentifier, remoteID: "r-live", uri: live.uri)])
    }

    func testRemoteIdentitiesAgreeWithFullItemProjection() throws {
        let store = try makeStore()
        let items = (0..<50).map { item("file-\($0).txt", remoteID: "r-\($0)") }
        try store.insertItems(items)

        let fromIdentities = Set(try store.remoteIdentities().map(\.remoteID))
        let fromItems = Set(try store.allItems().compactMap(\.remoteID))
        XCTAssertEqual(fromIdentities, fromItems)
        XCTAssertEqual(fromIdentities.count, 50)
    }
}
