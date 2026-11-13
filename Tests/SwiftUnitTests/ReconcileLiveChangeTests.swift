import XCTest
import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveAuthKit
import CloudreveEventCoordinator

/// The live event stream keeps applying remote changes while a full check lists folders one by
/// one. A file moved from a folder not yet listed into one already listed appears in neither
/// listing, and a restore applied during the trash listing is reverted by the stale trash page.
/// The check must leave any item with a newer non-reconciliation journal change alone.
final class ReconcileLiveChangeTests: XCTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        LiveChangeWireURLProtocol.responder = nil
        for url in cleanup {
            for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix)) }
        }
        cleanup.removeAll()
        super.tearDown()
    }

    func testItemMovedIntoListedFolderDuringScanIsNotTombstoned() async throws {
        let store = try makeStore()
        let folderA = item(remoteID: "r-a", name: "A", kind: .folder)
        let folderZ = item(remoteID: "r-z", name: "Z", kind: .folder)
        let moved = item(remoteID: "r-f", name: "Z/f.txt", parent: folderZ.itemIdentifier)
        try store.insertItems([folderA, folderZ, moved])
        let rootURI = rootURI
        LiveChangeWireURLProtocol.responder = { request in
            let uri = Self.uri(of: request)
            if Self.isRootInfo(request) { return Self.rootInfo }
            if uri.contains("trash") { return Self.listing([]) }
            if uri.hasSuffix("/A") { return Self.listing([]) }
            if uri.hasSuffix("/Z") {
                // The server moved Z/f to A/f after A was listed; the live event applies it now.
                var event = moved
                event.parentIdentifier = folderA.itemIdentifier
                event.name = "f.txt"
                event.uri = "\(rootURI)/A/f.txt"
                _ = try? store.commitProviderChange(item: event, oldParentIdentifier: folderZ.itemIdentifier, newParentIdentifier: folderA.itemIdentifier, kind: "updated", origin: "remote_event")
                return Self.listing([])
            }
            return Self.listing([Self.folder(id: "r-a", name: "A"), Self.folder(id: "r-z", name: "Z")])
        }
        try await reconcile(store)

        let kept = try XCTUnwrap(store.item(identifier: moved.itemIdentifier))
        XCTAssertFalse(kept.tombstone, "a file the live stream moved during the scan still exists on the server")
        XCTAssertEqual(kept.parentIdentifier, folderA.itemIdentifier)
    }

    func testItemDeletedWithoutLaterChangeIsStillTombstoned() async throws {
        let store = try makeStore()
        let gone = item(remoteID: "r-gone", name: "gone.txt")
        let other = item(remoteID: "r-other", name: "other.txt")
        try store.insertItems([gone, other])
        LiveChangeWireURLProtocol.responder = { request in
            let uri = Self.uri(of: request)
            if Self.isRootInfo(request) { return Self.rootInfo }
            if uri.contains("trash") { return Self.listing([]) }
            // A live change to a different item must not shield the deleted one.
            var event = other
            event.name = "renamed.txt"
            _ = try? store.commitProviderChange(item: event, oldParentIdentifier: event.parentIdentifier, newParentIdentifier: event.parentIdentifier, kind: "updated", origin: "remote_event")
            return Self.listing([])
        }
        try await reconcile(store)

        XCTAssertEqual(try store.item(identifier: gone.itemIdentifier)?.tombstone, true)
        XCTAssertEqual(try store.item(identifier: other.itemIdentifier)?.tombstone, false)
    }

    func testItemRestoredDuringTrashListingStaysRestored() async throws {
        let store = try makeStore()
        var trashed = item(remoteID: "r-t", name: "t.txt", parent: NSFileProviderItemIdentifier.trashContainer.rawValue)
        trashed.trashed = true
        trashed.trashOriginalParentIdentifier = NSFileProviderItemIdentifier.rootContainer.rawValue
        try store.insertItem(trashed)
        let restored = trashed
        LiveChangeWireURLProtocol.responder = { request in
            let uri = Self.uri(of: request)
            if Self.isRootInfo(request) { return Self.rootInfo }
            if uri.contains("trash") {
                // The restore lands while the (now stale) trash page is being served.
                var event = restored
                event.trashed = false
                event.parentIdentifier = NSFileProviderItemIdentifier.rootContainer.rawValue
                _ = try? store.commitProviderChange(item: event, oldParentIdentifier: NSFileProviderItemIdentifier.trashContainer.rawValue, newParentIdentifier: event.parentIdentifier, kind: "updated", origin: "remote_event")
                return Self.listing([Self.file(id: "r-t", name: "t.txt")])
            }
            return Self.listing([])
        }
        try await reconcile(store)

        let kept = try XCTUnwrap(store.item(identifier: restored.itemIdentifier))
        XCTAssertFalse(kept.trashed, "the stale trash listing must not undo the restore")
        XCTAssertFalse(kept.tombstone)
        XCTAssertEqual(kept.parentIdentifier, NSFileProviderItemIdentifier.rootContainer.rawValue)
    }

    func testCompactedJournalSkipsDeletionAndCompletes() async throws {
        let store = try makeStore()
        let gone = item(remoteID: "r-gone", name: "gone.txt")
        let other = item(remoteID: "r-other", name: "other.txt")
        try store.insertItems([gone, other])
        LiveChangeWireURLProtocol.responder = { request in
            let uri = Self.uri(of: request)
            if Self.isRootInfo(request) { return Self.rootInfo }
            if uri.contains("trash") { return Self.listing([]) }
            for name in ["one.txt", "two.txt"] {
                var event = other
                event.name = name
                _ = try? store.commitProviderChange(item: event, oldParentIdentifier: event.parentIdentifier, newParentIdentifier: event.parentIdentifier, kind: "updated", origin: "remote_event")
            }
            // Compaction removes rows after the scan start, so absence proves nothing.
            try? store.compactJournal(hardLimit: 1, retain: 1)
            return Self.listing([])
        }
        let before = try store.syncState().currentSequence
        try await reconcile(store)

        XCTAssertGreaterThan(try store.syncState().minSequence, before)
        XCTAssertEqual(try store.item(identifier: gone.itemIdentifier)?.tombstone, false, "deletion waits for a check with an intact journal")
        XCTAssertEqual(try store.syncState().reconcileStatus, "completed")
    }

    // MARK: - Fixture

    private let origin = URL(string: "https://cloudreve.example")!
    private var rootURI: String { (try? CloudreveRemoteURI.canonical("/", accountID: "account")) ?? "" }

    private var descriptor: DomainDescriptor {
        let scope = try! RemoteScope(origin: origin.absoluteString, accountID: "account", rootURI: rootURI)
        return DomainDescriptor(identifier: "crd-live-change-test", displayName: "Test", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential", capabilitySnapshot: .cloudreveV4(serverVersion: nil))
    }

    private func makeStore() throws -> SQLiteStateStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-live-change-\(UUID().uuidString).sqlite3")
        cleanup.append(url)
        let store = try SQLiteStateStore(url: url)
        try store.registerDomain(descriptor)
        return store
    }

    private func reconcile(_ store: SQLiteStateStore) async throws {
        let vault = MemoryCredentialVault()
        try vault.write(Credential(accessToken: "test-access", refreshToken: "test-refresh", accessExpiry: Date().addingTimeInterval(3_600)), reference: "credential")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveChangeWireURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = CloudreveReconciliationService(origin: origin, store: store, vault: vault, credentialReference: "credential", session: session, credentialRefresh: CredentialRefreshService(vault: vault, lockURL: nil, session: session))
        try await service.reconcile(descriptor: descriptor, reason: "test")
    }

    private func item(remoteID: String, name: String, kind: RemoteItemKind = .file, parent: String = NSFileProviderItemIdentifier.rootContainer.rawValue) -> RemoteItem {
        RemoteItem(remoteID: remoteID, parentIdentifier: parent, name: name, uri: "\(rootURI)/\(name)", kind: kind, contentType: kind == .folder ? UTType.folder.identifier : UTType.data.identifier, size: kind == .folder ? 0 : 3, version: ItemVersion(content: Data(name.utf8), metadata: Data(name.utf8)))
    }

    private static func uri(of request: URLRequest) -> String {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "uri" }?.value ?? ""
    }

    private static func isRootInfo(_ request: URLRequest) -> Bool {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.path == "/api/v4/file/info"
    }

    private static var rootInfo: Data { envelope(["type": 1, "id": "root", "name": "", "path": "cloudreve://my"]) }

    private static func listing(_ files: [[String: Any]]) -> Data {
        envelope(["files": files, "pagination": ["page": 1, "page_size": 500, "total_items": files.count]])
    }

    private static func file(id: String, name: String) -> [String: Any] {
        ["type": 0, "id": id, "name": name, "path": "cloudreve://my/\(name)", "size": 3, "capability": "rwd",
         "primary_entity": "entity-\(id)", "created_at": "2026-11-08T11:35:32Z", "updated_at": "2026-11-08T11:35:32Z"]
    }

    private static func folder(id: String, name: String) -> [String: Any] {
        ["type": 1, "id": id, "name": name, "path": "cloudreve://my/\(name)", "size": 0, "capability": "rwd",
         "created_at": "2026-11-08T11:35:32Z", "updated_at": "2026-11-08T11:35:32Z"]
    }

    private static func envelope(_ data: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: ["code": 0, "data": data])
    }
}

private final class LiveChangeWireURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> Data)?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cloudreve.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let body = Self.responder?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
