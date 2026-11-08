import XCTest
import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveAuthKit
import CloudreveEventCoordinator

/// Cloudreve creates a 0-byte file the moment an upload session opens and marks it with the
/// public `sys:upload_session_id` metadata until the upload completes. Recording such a file as a
/// remote item put a second item under the uploader's own name, so when the real upload landed
/// Finder renamed the user's file "name 2" (273 times in one folder). Unknown placeholders are
/// skipped everywhere a listing turns into items; items already in the store keep their handling.
private final class ProgressProbe: @unchecked Sendable {
    var duringListing: DomainCheckProgress?
    var duringTrash: DomainCheckProgress?
}

final class UploadPlaceholderTests: XCTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        PlaceholderWireURLProtocol.responder = nil
        for url in cleanup {
            for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix)) }
        }
        cleanup.removeAll()
        super.tearDown()
    }

    // MARK: - Metadata

    func testMetadataDecodingKeepsStringsAndDropsOtherValues() throws {
        struct Probe: Decodable { let metadata: CloudreveFileMetadata? }
        let json = ##"{"metadata":{"sys:upload_session_id":"s-1","customize:icon_color":"#fff","thumb:size":3,"tag:x":null}}"##
        let decoded = try JSONDecoder().decode(Probe.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.metadata?.values, ["sys:upload_session_id": "s-1", "customize:icon_color": "#fff"])
        XCTAssertNil(try JSONDecoder().decode(Probe.self, from: Data("{}".utf8)).metadata)
        XCTAssertEqual(try JSONDecoder().decode(Probe.self, from: Data(#"{"metadata":[]}"#.utf8)).metadata?.values, [:], "a malformed map must not fail the listing")
    }

    func testOnlyFilesWithAnUploadSessionCount() {
        func fields(type: Int, metadata: [String: String]) -> CloudreveFileFields {
            CloudreveFileFields(type: type, id: "x", name: "x", size: 0, permission: nil, capability: nil, createdAt: nil, updatedAt: nil, primaryEntity: nil, metadata: metadata)
        }
        XCTAssertTrue(fields(type: 0, metadata: [CloudreveFileFields.uploadSessionMetadataKey: "s"]).hasActiveUploadSession)
        XCTAssertFalse(fields(type: 0, metadata: [:]).hasActiveUploadSession)
        XCTAssertFalse(fields(type: 0, metadata: ["tag:x": "y"]).hasActiveUploadSession)
        XCTAssertFalse(fields(type: 1, metadata: [CloudreveFileFields.uploadSessionMetadataKey: "s"]).hasActiveUploadSession)
    }

    // MARK: - SSE enrichment

    func testPipelineIgnoresPendingUploadWithoutScheduledReconcile() async throws {
        let store = try makeStore()
        let pipeline = EventNormalizationPipeline(
            scopeGuard: EventScopeGuard(rootRemoteID: "root", rootURI: rootURI),
            enricher: ThrowingEnricher(error: EventEnrichmentError.pendingUpload),
            writer: EventJournalWriter(store: store)
        )
        let result = await pipeline.consume(RemoteEventHint(kind: .file, remoteID: "r-up"))
        XCTAssertEqual(result, .matched, ".unknown would start a full reconcile of the whole domain")
        let scopes = await pipeline.scopesNeedingReconciliation()
        XCTAssertTrue(scopes.isEmpty)
    }

    func testEnricherSkipsUnknownPlaceholderButKeepsKnownItem() async throws {
        let store = try makeStore()
        PlaceholderWireURLProtocol.responder = { request in
            let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value ?? ""
            return Self.envelope(Self.file(id: id, name: "\(id).bin", uploading: true))
        }
        let vault = try vault()
        let session = session()
        let enricher = CloudreveEventEnricher(origin: origin, rootURI: rootURI, rootRemoteID: "root", store: store, vault: vault, credentialReference: "credential", capabilitySnapshot: .cloudreveV4(serverVersion: nil), session: session, credentialRefresh: CredentialRefreshService(vault: vault, lockURL: nil, session: session))

        do {
            _ = try await enricher.enrich(RemoteEventHint(kind: .file, remoteID: "r-new"))
            XCTFail("a placeholder nothing local refers to must not become an item")
        } catch let error as EventEnrichmentError {
            XCTAssertEqual(error, .pendingUpload)
        }

        // A file already known locally (for example one receiving a new version) is still applied.
        try store.insertItem(item(remoteID: "r-known", name: "r-known.bin"))
        let change = try await enricher.enrich(RemoteEventHint(kind: .file, remoteID: "r-known"))
        XCTAssertEqual(change?.item.remoteID, "r-known")
    }

    // MARK: - Reconcile

    func testReconcileSkipsUnknownPlaceholderAndKeepsKnownOne() async throws {
        let store = try makeStore()
        let known = item(remoteID: "r-known", name: "known.bin")
        try store.insertItem(known)
        PlaceholderWireURLProtocol.responder = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let uri = components?.queryItems?.first { $0.name == "uri" }?.value
            if components?.path == "/api/v4/file/info" {
                return Self.envelope(["type": 1, "id": "root", "name": "", "path": "cloudreve://my"])
            }
            if uri == "cloudreve://trash" {
                return Self.envelope(["files": [], "pagination": ["page": 1, "page_size": 500, "total_items": 0]])
            }
            return Self.envelope([
                "files": [
                    Self.file(id: "r-new", name: "draft.bin", uploading: true),
                    Self.file(id: "r-known", name: "known.bin", uploading: true),
                    Self.file(id: "r-ok", name: "ok.txt", uploading: false)
                ],
                "pagination": ["page": 1, "page_size": 500, "total_items": 3]
            ])
        }
        let vault = try vault()
        let session = session()
        let service = CloudreveReconciliationService(origin: origin, store: store, vault: vault, credentialReference: "credential", session: session, credentialRefresh: CredentialRefreshService(vault: vault, lockURL: nil, session: session))
        try await service.reconcile(descriptor: descriptor, reason: "test")

        XCTAssertNil(try store.itemIdentifier(forRemoteID: "r-new"), "an unfinished upload is not a file yet")
        XCTAssertNotNil(try store.itemIdentifier(forRemoteID: "r-ok"))
        let kept = try XCTUnwrap(store.item(identifier: known.itemIdentifier))
        XCTAssertFalse(kept.tombstone, "a known item must never be read as deleted because an upload targets it")
    }

    /// Trashed entries are named by their trash path (cloudreve://trash/…). One of them used to
    /// throw scopeConflict for the whole run, so a full reconcile never reached deletion detection.
    func testReconcileSurvivesTrashPathsAndStillDetectsDeletions() async throws {
        let store = try makeStore()
        let trashed = item(remoteID: "r-trashed", name: "trashed.txt")
        let gone = item(remoteID: "r-gone", name: "gone.txt")
        try store.insertItems([trashed, gone])
        PlaceholderWireURLProtocol.responder = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let uri = components?.queryItems?.first { $0.name == "uri" }?.value
            if components?.path == "/api/v4/file/info" {
                return Self.envelope(["type": 1, "id": "root", "name": "", "path": "cloudreve://my"])
            }
            if uri == "cloudreve://trash" {
                return Self.envelope([
                    "files": [[
                        "type": 0, "id": "r-trashed", "name": "trashed.txt", "path": "cloudreve://trash/trashed.txt", "size": 3,
                        "metadata": [CloudreveFileFields.restoreURIMetadataKey: "cloudreve://my/trashed.txt"]
                    ] as [String: Any]],
                    "pagination": ["page": 1, "page_size": 500, "total_items": 1]
                ])
            }
            return Self.envelope(["files": [Self.file(id: "r-ok", name: "ok.txt", uploading: false)], "pagination": ["page": 1, "page_size": 500, "total_items": 1]])
        }
        let vault = try vault()
        let session = session()
        let service = CloudreveReconciliationService(origin: origin, store: store, vault: vault, credentialReference: "credential", session: session, credentialRefresh: CredentialRefreshService(vault: vault, lockURL: nil, session: session))
        try await service.reconcile(descriptor: descriptor, reason: "test")

        XCTAssertEqual(try store.item(identifier: gone.itemIdentifier)?.tombstone, true, "the run must reach deletion detection")
        XCTAssertEqual(try store.item(identifier: trashed.itemIdentifier)?.tombstone, false, "an item that is only in the trash is not a permanent deletion")
    }

    /// The full check records how far it has come so the app can draw an estimated progress bar.
    func testReconcileRecordsProgressAgainstThePreviousItemCount() async throws {
        let store = try makeStore()
        try store.insertItems([item(remoteID: "r-a", name: "a.txt"), item(remoteID: "r-b", name: "b.txt"), item(remoteID: "r-c", name: "c.txt")])
        let observed = ProgressProbe()
        PlaceholderWireURLProtocol.responder = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let uri = components?.queryItems?.first { $0.name == "uri" }?.value
            if components?.path == "/api/v4/file/info" {
                return Self.envelope(["type": 1, "id": "root", "name": "", "path": "cloudreve://my"])
            }
            if uri == "cloudreve://trash" {
                observed.duringTrash = try? store.activeCheckProgress()
                return Self.envelope(["files": [], "pagination": ["page": 1, "page_size": 500, "total_items": 0]])
            }
            observed.duringListing = try? store.activeCheckProgress()
            return Self.envelope(["files": [Self.file(id: "r-a", name: "a.txt", uploading: false), Self.file(id: "r-b", name: "b.txt", uploading: false)], "pagination": ["page": 1, "page_size": 500, "total_items": 2]])
        }
        let vault = try vault()
        let session = session()
        let service = CloudreveReconciliationService(origin: origin, store: store, vault: vault, credentialReference: "credential", session: session, credentialRefresh: CredentialRefreshService(vault: vault, lockURL: nil, session: session))
        try await service.reconcile(descriptor: descriptor, reason: "test")

        XCTAssertEqual(observed.duringListing?.phase, .scanningFiles)
        XCTAssertEqual(observed.duringListing?.scannedItems, 0)
        XCTAssertEqual(observed.duringListing?.expectedItems, 3, "the estimate is what the previous check left behind")
        XCTAssertEqual(observed.duringTrash?.phase, .scanningTrash)
        XCTAssertEqual(observed.duringTrash?.scannedItems, 2)
        XCTAssertEqual(observed.duringTrash?.expectedItems, 3)
        XCTAssertNil(try store.activeCheckProgress(), "a completed check reports no progress")
    }

    // MARK: - Fixture

    private let origin = URL(string: "https://cloudreve.example")!
    private var rootURI: String { (try? CloudreveRemoteURI.canonical("/", accountID: "account")) ?? "" }

    private var descriptor: DomainDescriptor {
        let scope = try! RemoteScope(origin: origin.absoluteString, accountID: "account", rootURI: rootURI)
        return DomainDescriptor(identifier: "crd-placeholder-test", displayName: "Test", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential", capabilitySnapshot: .cloudreveV4(serverVersion: nil))
    }

    private func makeStore() throws -> SQLiteStateStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-placeholder-\(UUID().uuidString).sqlite3")
        cleanup.append(url)
        let store = try SQLiteStateStore(url: url)
        try store.registerDomain(descriptor)
        return store
    }

    private func vault() throws -> MemoryCredentialVault {
        let vault = MemoryCredentialVault()
        try vault.write(Credential(accessToken: "test-access", refreshToken: "test-refresh", accessExpiry: Date().addingTimeInterval(3_600)), reference: "credential")
        return vault
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaceholderWireURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func item(remoteID: String, name: String) -> RemoteItem {
        RemoteItem(remoteID: remoteID, parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: name, uri: "\(rootURI)/\(name)", kind: .file, contentType: UTType.data.identifier, size: 3, version: ItemVersion(content: Data(name.utf8), metadata: Data(name.utf8)))
    }

    private static func file(id: String, name: String, uploading: Bool) -> [String: Any] {
        var file: [String: Any] = [
            "type": 0, "id": id, "name": name, "path": "cloudreve://my/\(name)",
            "size": uploading ? 0 : 3, "capability": "rwd",
            "created_at": "2026-11-08T11:35:32Z", "updated_at": "2026-11-08T11:35:32Z"
        ]
        if uploading {
            file["metadata"] = [CloudreveFileFields.uploadSessionMetadataKey: "session-\(id)"]
        } else {
            file["primary_entity"] = "entity-\(id)"
        }
        return file
    }

    private static func envelope(_ data: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: ["code": 0, "data": data])
    }
}

private struct ThrowingEnricher: RemoteEventEnricher {
    let error: Error
    func enrich(_ hint: RemoteEventHint) async throws -> EnrichedRemoteChange? { throw error }
}

private final class PlaceholderWireURLProtocol: URLProtocol {
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
