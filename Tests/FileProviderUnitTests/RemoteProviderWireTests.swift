import XCTest
import Foundation
import FileProvider
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveAuthKit
import CloudreveFileProviderKit

final class RemoteProviderWireTests: XCTestCase {
    func testDirectoryPageNumberHydrationStopsAtReportedTotal() async throws {
        try await assertDirectoryHydration(mode: .page, expectedQueries: ["page=1", "page=2"])
    }

    func testDirectoryCursorHydrationDoesNotRestartPagePaginationAtEnd() async throws {
        try await assertDirectoryHydration(mode: .cursor, expectedQueries: ["page=1", "next_page_token=cursor-1"])
    }

    private func assertDirectoryHydration(mode: DirectoryPageWireURLProtocol.Mode, expectedQueries: [String]) async throws {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-page-wire-\(UUID().uuidString).sqlite3")
        defer {
            DirectoryPageWireURLProtocol.clear()
            try? FileManager.default.removeItem(at: storeURL)
            for suffix in ["-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
            }
        }
        let store = try SQLiteStateStore(url: storeURL)
        let vault = MemoryCredentialVault()
        let domainIdentifier = CloudreveIdentifier.domain()
        let rootURI = try CloudreveRemoteURI.canonical("/", accountID: "account")
        let capabilities = CapabilitySnapshot(
            completePagination: .verified,
            cursorPagination: .verified,
            snapshotSafePagination: .verified
        )
        let scope = try RemoteScope(origin: "https://cloudreve.example", accountID: "account", rootURI: rootURI)
        try store.registerDomain(DomainDescriptor(identifier: domainIdentifier, displayName: "Page Test", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential", capabilitySnapshot: capabilities))
        try vault.write(Credential(accessToken: "unit-token", refreshToken: "refresh-token", accessExpiry: Date().addingTimeInterval(3_600)), reference: "credential")
        let state = DirectoryPageWireURLProtocol.State(mode: mode)
        DirectoryPageWireURLProtocol.install(state)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DirectoryPageWireURLProtocol.self]
        var backend: NimbusSyncRemoteBackend? = NimbusSyncRemoteBackend(
            origin: URL(string: "https://cloudreve.example")!,
            rootURI: rootURI,
            store: store,
            vault: vault,
            credentialReference: "credential",
            capabilitySnapshot: capabilities,
            providerName: "unverified",
            secretVault: MemoryOpaqueSecretVault(),
            domainIdentifier: domainIdentifier,
            urlSessionConfiguration: configuration
        )
        let context = FileProviderOperationContext(itemIdentifier: .rootContainer, progress: Progress(totalUnitCount: 1), registrar: NoopURLSessionTaskRegistrar(), cancellation: CancellationToken())

        // A single enumeration callback hydrates every remote page and only
        // then publishes the snapshot; earlier builds failed each callback
        // until the system had retried once per remote page.
        let page = try await backend!.childrenPage(parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, cursor: nil, context: context)
        XCTAssertTrue(page.complete)
        XCTAssertEqual(page.items.map(\.remoteID), ["remote-page-1", "remote-page-2"])
        XCTAssertEqual(state.requestedQueries, expectedQueries)

        // A fresh complete snapshot is served locally without new requests.
        let cached = try await backend!.childrenPage(parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, cursor: nil, context: context)
        backend = nil
        XCTAssertEqual(cached.items.map(\.remoteID), ["remote-page-1", "remote-page-2"])
        XCTAssertEqual(state.requestedQueries, expectedQueries)
    }

    /// A file an upload session is still writing (Cloudreve's 0-byte placeholder) must not be
    /// listed: next to the local item being uploaded under the same name it made Finder rename the
    /// real file "name 2" when the upload landed. An item the store already knows stays listed.
    func testDirectoryListingSkipsUnknownUploadPlaceholders() async throws {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-placeholder-wire-\(UUID().uuidString).sqlite3")
        defer {
            DirectoryPageWireURLProtocol.clear()
            for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix)) }
        }
        let store = try SQLiteStateStore(url: storeURL)
        let vault = MemoryCredentialVault()
        let domainIdentifier = CloudreveIdentifier.domain()
        let rootURI = try CloudreveRemoteURI.canonical("/", accountID: "account")
        let capabilities = CapabilitySnapshot(completePagination: .verified, cursorPagination: .verified, snapshotSafePagination: .verified)
        let scope = try RemoteScope(origin: "https://cloudreve.example", accountID: "account", rootURI: rootURI)
        try store.registerDomain(DomainDescriptor(identifier: domainIdentifier, displayName: "Placeholder Test", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential", capabilitySnapshot: capabilities))
        try vault.write(Credential(accessToken: "test-access", refreshToken: "test-refresh", accessExpiry: Date().addingTimeInterval(3_600)), reference: "credential")
        try store.insertItem(RemoteItem(remoteID: "remote-known-uploading", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "known.bin", uri: try CloudreveRemoteURI.append(rootURI, name: "known.bin"), kind: .file, contentType: "public.data", size: 3, version: ItemVersion(content: Data("k".utf8), metadata: Data("k".utf8))))
        func uploading(_ id: String, _ name: String) -> [String: Any] {
            ["type": 0, "id": id, "name": name, "path": "/\(name)", "size": 0, "permission": "r", "capability": "rwd",
             "created_at": "2026-11-08T11:35:32Z", "updated_at": "2026-11-08T11:35:32Z",
             "metadata": ["sys:upload_session_id": "session-\(id)", "thumb:disabled": 1] as [String: Any]]
        }
        let state = DirectoryPageWireURLProtocol.State(mode: .page, extraFiles: [uploading("remote-new-uploading", "page-1.txt"), uploading("remote-known-uploading", "known.bin")])
        DirectoryPageWireURLProtocol.install(state)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DirectoryPageWireURLProtocol.self]
        var backend: NimbusSyncRemoteBackend? = NimbusSyncRemoteBackend(origin: URL(string: "https://cloudreve.example")!, rootURI: rootURI, store: store, vault: vault, credentialReference: "credential", capabilitySnapshot: capabilities, providerName: "unverified", secretVault: MemoryOpaqueSecretVault(), domainIdentifier: domainIdentifier, urlSessionConfiguration: configuration)
        let context = FileProviderOperationContext(itemIdentifier: .rootContainer, progress: Progress(totalUnitCount: 1), registrar: NoopURLSessionTaskRegistrar(), cancellation: CancellationToken())
        let page = try await backend!.childrenPage(parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, cursor: nil, context: context)
        backend = nil

        XCTAssertEqual(Set(page.items.compactMap(\.remoteID)), ["remote-page-1", "remote-known-uploading", "remote-page-2"])
        XCTAssertNil(try store.itemIdentifier(forRemoteID: "remote-new-uploading"))
        XCTAssertEqual(state.requestedQueries, ["page=1", "page=2"])
    }

    /// The account-wide trash names entries by their trash path, which used to make every Trash
    /// enumeration fail with -2005. Unaddressable entries are left out; pagination still follows
    /// what the server listed.
    func testTrashListingSkipsTrashPathEntriesWithoutFailing() async throws {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-trash-wire-\(UUID().uuidString).sqlite3")
        defer {
            DirectoryPageWireURLProtocol.clear()
            for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix)) }
        }
        let store = try SQLiteStateStore(url: storeURL)
        let vault = MemoryCredentialVault()
        let domainIdentifier = CloudreveIdentifier.domain()
        let rootURI = try CloudreveRemoteURI.canonical("/", accountID: "account")
        let capabilities = CapabilitySnapshot.cloudreveV4(serverVersion: nil)
        let scope = try RemoteScope(origin: "https://cloudreve.example", accountID: "account", rootURI: rootURI)
        try store.registerDomain(DomainDescriptor(identifier: domainIdentifier, displayName: "Trash Test", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential", capabilitySnapshot: capabilities))
        try vault.write(Credential(accessToken: "test-access", refreshToken: "test-refresh", accessExpiry: Date().addingTimeInterval(3_600)), reference: "credential")
        let trashEntry: [String: Any] = [
            "type": 0, "id": "remote-in-trash", "name": "old.txt", "path": "cloudreve://trash/old.txt", "size": 3,
            "permission": "r", "capability": "rwd", "created_at": "2026-11-08T00:00:00Z", "updated_at": "2026-11-08T00:00:00Z",
            "metadata": ["sys:restore_uri": "cloudreve://my/old.txt"] as [String: Any]
        ]
        let state = DirectoryPageWireURLProtocol.State(mode: .page, extraFiles: [trashEntry])
        DirectoryPageWireURLProtocol.install(state)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DirectoryPageWireURLProtocol.self]
        var backend: NimbusSyncRemoteBackend? = NimbusSyncRemoteBackend(origin: URL(string: "https://cloudreve.example")!, rootURI: rootURI, store: store, vault: vault, credentialReference: "credential", capabilitySnapshot: capabilities, providerName: "local", secretVault: MemoryOpaqueSecretVault(), domainIdentifier: domainIdentifier, urlSessionConfiguration: configuration)
        let context = FileProviderOperationContext(itemIdentifier: .trashContainer, progress: Progress(totalUnitCount: 1), registrar: NoopURLSessionTaskRegistrar(), cancellation: CancellationToken())
        let items = try await backend!.trashItems(context: context)
        backend = nil

        XCTAssertFalse(items.contains { $0.remoteID == "remote-in-trash" })
        XCTAssertTrue(items.allSatisfy(\.trashed))
        // Page 1 already carried two listed entries against a total of two: no further request.
        XCTAssertEqual(state.requestedQueries, ["page=1"])
    }

    /// The pre-download refresh looks the item up by path. When another object now lives there
    /// (the item's own object was deleted or replaced), the stale item must be reported as gone
    /// rather than re-bound to that object, which collided with the item that owns it.
    func testDownloadRefusesToRebindItemToAnotherObjectAtTheSamePath() async throws {
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: 4)
        defer { fixture.cleanup() }
        var stale = fixture.template
        stale.remoteID = "remote-deleted-placeholder"
        let store = try SQLiteStateStore(url: fixture.storeURL)
        try store.insertItem(stale)
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10)
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-stale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        do {
            _ = try await backend!.fetchContent(identifier: stale.itemIdentifier, expectedVersion: nil, destination: destination, context: fixture.makeContext(itemIdentifier: stale.itemIdentifier))
            XCTFail("the path now belongs to another object")
        } catch let failure as CoreFailure {
            XCTAssertEqual(failure.code, .notFound)
            XCTAssertEqual(failure.redactedContext["stage"], "remote_identity_changed")
        }
        backend = nil

        XCTAssertEqual(try store.item(identifier: stale.itemIdentifier)?.remoteID, "remote-deleted-placeholder", "the stale item keeps its own identity")
        XCTAssertEqual(try store.item(identifier: stale.itemIdentifier)?.tombstone, true, "the stale item is deleted, so the system stops asking for it")
        XCTAssertTrue(CoreFailure(code: .notFound, retryable: false, redactedContext: ["stage": "remote_identity_changed"]).isRemoteIdentityChanged)
        XCTAssertFalse(CoreFailure(code: .notFound, retryable: false).isRemoteIdentityChanged, "a plain 404 may be a stale path, left to the next check")
        XCTAssertNil(try store.itemIdentifier(forRemoteID: "remote-wire-remote"))
        XCTAssertFalse(protocolState.requests.contains { $0.url.path == "/api/v4/file/url" }, "nothing is downloaded for a gone item")
        XCTAssertEqual(FileProviderErrorMapper.map(CoreFailure(code: .notFound, retryable: false)).code, NSFileProviderError.noSuchItem.rawValue)
    }

    /// The system only downloads an item it holds, so the deletion of a stale one must reach the
    /// working set even when nothing else marked the item or its folder as visible (a folder made
    /// in Finder is never listed by the system). It must also reach it when an earlier attempt had
    /// already deleted the item without the system hearing of it.
    func testStaleDownloadDeletionReachesTheWorkingSet() async throws {
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: 4)
        defer { fixture.cleanup() }
        let store = try SQLiteStateStore(url: fixture.storeURL)
        let folder = RemoteItem(itemIdentifier: CloudreveIdentifier.item(), remoteID: "remote-folder", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "made-in-finder", uri: try CloudreveRemoteURI.append(fixture.rootURI, name: "made-in-finder"), kind: .folder, contentType: "public.folder", size: 0, version: ItemVersion(content: Data("folder".utf8), metadata: Data("folder".utf8)), canRead: true, canWrite: true)
        try store.insertItem(folder)
        var stale = fixture.template
        stale.remoteID = "remote-deleted-placeholder"
        stale.parentIdentifier = folder.itemIdentifier
        stale.uri = try CloudreveRemoteURI.append(folder.uri, name: "payload.bin")
        try store.insertItem(stale)
        let workingSet = NSFileProviderItemIdentifier.workingSet.rawValue

        for attempt in 1...2 {
            let before = try store.currentAnchor(domainIdentifier: fixture.domainIdentifier, scope: workingSet)
            var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: UploadWireURLProtocol.State(provider: "remote", sourceSize: 10))
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-stale-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: destination) }
            do {
                _ = try await backend!.fetchContent(identifier: stale.itemIdentifier, expectedVersion: nil, destination: destination, context: fixture.makeContext(itemIdentifier: stale.itemIdentifier))
                XCTFail("the path now belongs to another object")
            } catch let failure as CoreFailure {
                XCTAssertTrue(failure.isRemoteIdentityChanged)
            }
            backend = nil

            let changes = try store.enumerateChanges(domainIdentifier: fixture.domainIdentifier, scope: workingSet, from: before).changes
            XCTAssertTrue(changes.contains { $0.itemIdentifier == stale.itemIdentifier && $0.kind == "deleted" }, "attempt \(attempt): the system must hear the item is gone")
        }
    }

    /// Delete names its target by path. A stale item shares its path with the real file (the old
    /// upload-placeholder bug), so deleting it must never delete that file; it is gone already.
    func testDeletingAStaleItemNeverDeletesTheFileNowAtItsPath() async throws {
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: 4)
        defer { fixture.cleanup() }
        var stale = fixture.template
        stale.remoteID = "remote-deleted-placeholder"
        stale.canTrash = true
        try SQLiteStateStore(url: fixture.storeURL).insertItem(stale)
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10)
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)

        try await backend!.delete(DeleteRequest(itemIdentifier: stale.itemIdentifier, expectedVersion: stale.version.content, recursive: false, replayKey: "delete-stale"), context: fixture.makeContext(itemIdentifier: stale.itemIdentifier))
        backend = nil

        XCTAssertTrue(protocolState.requests.contains { $0.url.path == "/api/v4/file/info" }, "the path is checked first")
        XCTAssertFalse(protocolState.requests.contains { $0.url.path == "/api/v4/file" && $0.method == "DELETE" }, "the file now at the path is left alone")
    }

    func testDeletingTheCurrentObjectStillDeletesByPath() async throws {
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: 4)
        defer { fixture.cleanup() }
        var current = fixture.template
        current.remoteID = "remote-wire-remote"
        current.canTrash = true
        try SQLiteStateStore(url: fixture.storeURL).insertItem(current)
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10)
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)

        try await backend!.delete(DeleteRequest(itemIdentifier: current.itemIdentifier, expectedVersion: current.version.content, recursive: false, replayKey: "delete-current"), context: fixture.makeContext(itemIdentifier: current.itemIdentifier))
        backend = nil

        let deletion = try XCTUnwrap(protocolState.requests.first { $0.url.path == "/api/v4/file" && $0.method == "DELETE" })
        let body = try XCTUnwrap(deletion.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["uris"] as? [String], [current.uri])
        XCTAssertEqual(body["skip_soft_delete"] as? Bool, false, "still soft-deleted into the server trash")
    }

    /// Moving a stale item to the trash must not trash the real file at its path either. The stale
    /// item is deleted instead and the deletion is journaled for the working set.
    func testTrashingAStaleItemDeletesItInsteadOfTrashingTheFileAtItsPath() async throws {
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: 4)
        defer { fixture.cleanup() }
        let store = try SQLiteStateStore(url: fixture.storeURL)
        var stale = fixture.template
        stale.remoteID = "remote-deleted-placeholder"
        stale.canTrash = true
        try store.insertItem(stale)
        let workingSet = NSFileProviderItemIdentifier.workingSet.rawValue
        let before = try store.currentAnchor(domainIdentifier: fixture.domainIdentifier, scope: workingSet)
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10)
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)

        do {
            _ = try await backend!.trash(TrashRequest(item: stale, expectedVersion: stale.version.content, replayKey: "trash-stale"), context: fixture.makeContext(itemIdentifier: stale.itemIdentifier))
            XCTFail("the path now belongs to another object")
        } catch let failure as CoreFailure {
            XCTAssertTrue(failure.isRemoteIdentityChanged)
        }
        backend = nil

        XCTAssertFalse(protocolState.requests.contains { $0.url.path == "/api/v4/file" && $0.method == "DELETE" }, "the file now at the path is not trashed")
        XCTAssertEqual(try store.item(identifier: stale.itemIdentifier)?.tombstone, true)
        let changes = try store.enumerateChanges(domainIdentifier: fixture.domainIdentifier, scope: workingSet, from: before).changes
        XCTAssertTrue(changes.contains { $0.itemIdentifier == stale.itemIdentifier && $0.kind == "deleted" })
    }

    /// Cloudreve answers 40016 when nothing is at the path (or its parent). The item is gone, so
    /// delete succeeds locally and trash deletes it instead of failing with an unknown outcome.
    func testDeleteAndTrashTreatAnEmptyPathAsGone() async throws {
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: 4)
        defer { fixture.cleanup() }
        let store = try SQLiteStateStore(url: fixture.storeURL)
        var moved = fixture.template
        moved.remoteID = "remote-moved-away"
        moved.canTrash = true
        try store.insertItem(moved)
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10)
        protocolState.fileInfoAPICode = 40016
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)
        let context = fixture.makeContext(itemIdentifier: moved.itemIdentifier)

        try await backend!.delete(DeleteRequest(itemIdentifier: moved.itemIdentifier, expectedVersion: moved.version.content, recursive: false, replayKey: "delete-moved"), context: context)
        do {
            _ = try await backend!.trash(TrashRequest(item: moved, expectedVersion: moved.version.content, replayKey: "trash-moved"), context: context)
            XCTFail("nothing is at the path to trash")
        } catch let failure as CoreFailure {
            XCTAssertTrue(failure.isRemotePathEmpty)
            XCTAssertTrue(failure.isRemoteObjectGone)
            XCTAssertFalse(failure.isRemoteIdentityChanged)
        }
        backend = nil

        XCTAssertFalse(protocolState.requests.contains { $0.url.path == "/api/v4/file" && $0.method == "DELETE" }, "nothing is deleted by path")
        XCTAssertEqual(try store.item(identifier: moved.itemIdentifier)?.tombstone, true)
    }

    /// Any other `file/info` failure proves nothing about the object, so nothing is deleted.
    func testDeleteFailsClosedWhenThePathCannotBeChecked() async throws {
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: 4)
        defer { fixture.cleanup() }
        var item = fixture.template
        item.remoteID = "remote-wire-remote"
        item.canTrash = true
        try SQLiteStateStore(url: fixture.storeURL).insertItem(item)
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10)
        protocolState.fileInfoAPICode = 50001
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)

        do {
            try await backend!.delete(DeleteRequest(itemIdentifier: item.itemIdentifier, expectedVersion: item.version.content, recursive: false, replayKey: "delete-unchecked"), context: fixture.makeContext(itemIdentifier: item.itemIdentifier))
            XCTFail("the identity could not be confirmed")
        } catch let failure as CoreFailure {
            XCTAssertFalse(failure.isRemoteObjectGone)
            XCTAssertEqual(failure.redactedContext["api_code"], "50001")
        }
        backend = nil

        XCTAssertFalse(protocolState.requests.contains { $0.url.path == "/api/v4/file" && $0.method == "DELETE" })
    }

    /// A rename or move the item already has is not sent again: the system may re-issue a committed
    /// request on a newer base, and renaming to the current name (or moving into the current
    /// folder) must neither reach the server nor fail.
    func testRenameAndMoveToTheCurrentStateSendNothing() async throws {
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: 4)
        defer { fixture.cleanup() }
        var item = fixture.template
        item.remoteID = "remote-wire-remote"
        try SQLiteStateStore(url: fixture.storeURL).insertItem(item)
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10)
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)

        let result = try await backend!.modify(ModifyRequest(item: item, expectedVersion: item.version.content, changedFields: [.filename, .parentItemIdentifier], contents: nil, options: [], replayKey: "no-op"), context: fixture.makeContext(itemIdentifier: item.itemIdentifier))
        backend = nil

        XCTAssertEqual(result.name, item.name)
        XCTAssertEqual(result.parentIdentifier, item.parentIdentifier)
        XCTAssertTrue(protocolState.requests.isEmpty, "nothing is sent for a rename or move already done")
    }

    /// Emptying the Trash used to purge by the item's original path, which a trashed item keeps:
    /// a new file created at that path was permanently deleted, and an empty path was taken for a
    /// successful purge. A trashed item is now deleted locally only and stays in the server trash.
    func testPurgingATrashedItemNeverDeletesByItsOriginalPath() async throws {
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: 4, allowsPurge: true)
        defer { fixture.cleanup() }
        let store = try SQLiteStateStore(url: fixture.storeURL)
        var item = fixture.template
        item.remoteID = "remote-trashed-original"
        item.canTrash = true
        item.canDelete = true
        try store.insertItem(item)
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10)
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)
        var trashed = item
        trashed.trashed = true
        trashed.trashOriginalParentIdentifier = item.parentIdentifier
        trashed.parentIdentifier = NSFileProviderItemIdentifier.trashContainer.rawValue
        try store.insertItem(trashed)

        // `file/info` at the original path now answers with another object (remote-wire-remote).
        try await backend!.delete(DeleteRequest(itemIdentifier: trashed.itemIdentifier, expectedVersion: trashed.version.content, recursive: false, replayKey: "purge-trashed"), context: fixture.makeContext(itemIdentifier: trashed.itemIdentifier))
        backend = nil

        XCTAssertFalse(protocolState.requests.contains { $0.url.path == "/api/v4/file" && $0.method == "DELETE" }, "the file now at the original path is never purged")
        XCTAssertTrue(protocolState.requests.isEmpty, "nothing is sent for a trashed item")
    }

    /// Rename names its target by path like delete and trash: a stale item must not rename the
    /// other file at its path. It is deleted instead and the system hears about it.
    func testRenamingAStaleItemDeletesItInsteadOfRenamingTheFileAtItsPath() async throws {
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: 4)
        defer { fixture.cleanup() }
        let store = try SQLiteStateStore(url: fixture.storeURL)
        var stale = fixture.template
        stale.remoteID = "remote-deleted-placeholder"
        try store.insertItem(stale)
        let workingSet = NSFileProviderItemIdentifier.workingSet.rawValue
        let before = try store.currentAnchor(domainIdentifier: fixture.domainIdentifier, scope: workingSet)
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10)
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)
        var renamed = stale
        renamed.name = "renamed.bin"

        do {
            _ = try await backend!.modify(ModifyRequest(item: renamed, expectedVersion: stale.version.content, changedFields: [.filename], contents: nil, options: [], replayKey: "rename-stale"), context: fixture.makeContext(itemIdentifier: stale.itemIdentifier))
            XCTFail("the path now belongs to another object")
        } catch let failure as CoreFailure {
            XCTAssertTrue(failure.isRemoteIdentityChanged)
        }
        backend = nil

        XCTAssertFalse(protocolState.requests.contains { $0.url.path == "/api/v4/file/rename" }, "the file now at the path is not renamed")
        XCTAssertEqual(try store.item(identifier: stale.itemIdentifier)?.tombstone, true)
        let changes = try store.enumerateChanges(domainIdentifier: fixture.domainIdentifier, scope: workingSet, from: before).changes
        XCTAssertTrue(changes.contains { $0.itemIdentifier == stale.itemIdentifier && $0.kind == "deleted" })
    }

    func testMovingAStaleItemDeletesItInsteadOfMovingTheFileAtItsPath() async throws {
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: 4)
        defer { fixture.cleanup() }
        let store = try SQLiteStateStore(url: fixture.storeURL)
        let folder = try makeWireFolder(name: "Destination", fixture: fixture, store: store)
        var stale = fixture.template
        stale.remoteID = "remote-deleted-placeholder"
        try store.insertItem(stale)
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10)
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)
        var moved = stale
        moved.parentIdentifier = folder.itemIdentifier

        do {
            _ = try await backend!.modify(ModifyRequest(item: moved, expectedVersion: stale.version.content, changedFields: [.parentItemIdentifier], contents: nil, options: [], replayKey: "move-stale"), context: fixture.makeContext(itemIdentifier: stale.itemIdentifier))
            XCTFail("the path now belongs to another object")
        } catch let failure as CoreFailure {
            XCTAssertTrue(failure.isRemoteIdentityChanged)
        }
        backend = nil

        XCTAssertFalse(protocolState.requests.contains { $0.url.path == "/api/v4/file/move" }, "the file now at the path is not moved")
        XCTAssertEqual(try store.item(identifier: stale.itemIdentifier)?.tombstone, true)
    }

    /// A move leaves the content version alone and `file/move` returns no item. When the metadata
    /// version did not change either, the system sent the same base for A→B, B→A and A→B, and the
    /// third move was answered with the first one's stored result without reaching the server.
    /// Each step's base here is what the system really holds: the projected metadata version.
    func testMovingBackAndForthReachesTheServerEveryTime() async throws {
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: 4)
        defer { fixture.cleanup() }
        let store = try SQLiteStateStore(url: fixture.storeURL)
        let folderA = try makeWireFolder(name: "A", fixture: fixture, store: store)
        let folderB = try makeWireFolder(name: "B", fixture: fixture, store: store)
        var item = fixture.template
        item.remoteID = "remote-wire-remote"
        item.parentIdentifier = folderA.itemIdentifier
        item.uri = try CloudreveRemoteURI.append(folderA.uri, name: item.name)
        try store.insertItem(item)
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10)
        let backend = fixture.makeBackend(protocolState: protocolState)
        let coordinator = AsyncFileProviderMutationCoordinator(store: store, backend: backend)
        var seenBases: Set<Data> = []

        for (step, destination) in [folderB, folderA, folderB].enumerated() {
            let current = try XCTUnwrap(try store.item(identifier: item.itemIdentifier))
            let baseMetadataVersion = NimbusSyncFileProviderItem(model: current).itemVersion.metadataVersion
            XCTAssertTrue(seenBases.insert(baseMetadataVersion).inserted, "step \(step) has its own base metadata version")
            var moved = current
            moved.parentIdentifier = destination.itemIdentifier
            let result = try await coordinator.modify(item: moved, baseVersion: current.version.content, baseMetadataVersion: baseMetadataVersion, fields: [.parentItemIdentifier], contents: nil, options: [], context: fixture.makeContext(itemIdentifier: item.itemIdentifier))
            XCTAssertEqual(result.parentIdentifier, destination.itemIdentifier, "step \(step)")
        }

        let moves = protocolState.requests.filter { $0.url.path == "/api/v4/file/move" }
        XCTAssertEqual(moves.count, 3, "every move reached the server")
        let lastBody = try XCTUnwrap(moves.last?.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(lastBody["dst"] as? String, folderB.uri)
        XCTAssertEqual(try store.item(identifier: item.itemIdentifier)?.parentIdentifier, folderB.itemIdentifier)
    }

    private func makeWireFolder(name: String, fixture: UploadWireFixture, store: SQLiteStateStore) throws -> RemoteItem {
        let folder = RemoteItem(itemIdentifier: CloudreveIdentifier.item(), remoteID: "remote-folder-\(name)", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: name, uri: try CloudreveRemoteURI.append(fixture.rootURI, name: name), kind: .folder, contentType: "public.folder", size: 0, version: ItemVersion(content: Data(name.utf8), metadata: Data(name.utf8)), canRead: true, canWrite: true, canAddChildren: true)
        try store.insertItem(folder)
        return folder
    }

    func testQiniuAsyncUploadUsesOneBasedPartsAndUpTokenOnStorageOnly() async throws {
        let fixture = try UploadWireFixture(provider: "qiniu", chunkSize: 4)
        defer { fixture.cleanup() }
        let source = try fixture.makeSource(Data("0123456789".utf8))
        let protocolState = UploadWireURLProtocol.State(provider: "qiniu", sourceSize: 10)
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)
        let context = fixture.makeContext(itemIdentifier: fixture.template.itemIdentifier)

        let result = try await backend!.create(
            CreateRequest(template: fixture.template, contents: source, replayKey: "wire-qiniu"),
            context: context
        )
        backend = nil

        XCTAssertEqual(result.remoteID, "remote-wire-qiniu")
        let requests = protocolState.requests
        let partRequests = requests.filter { $0.url.path.hasPrefix("/qiniu/upload/") && $0.url.path != "/qiniu/upload/" }
        XCTAssertEqual(partRequests.map(\.url.path), ["/qiniu/upload/1", "/qiniu/upload/2", "/qiniu/upload/3"])
        XCTAssertEqual(partRequests.map(\.method), ["PUT", "PUT", "PUT"])
        XCTAssertTrue(partRequests.allSatisfy { $0.authorization == "UpToken qiniu-token" })
        XCTAssertTrue(partRequests.allSatisfy { $0.authorization?.hasPrefix("Bearer ") == false })
        XCTAssertEqual(partRequests.map(\.body), [Data("0123".utf8), Data("4567".utf8), Data("89".utf8)])

        let completion = try XCTUnwrap(requests.first { $0.url.path == "/qiniu/upload" && $0.method == "POST" })
        XCTAssertEqual(completion.authorization, "UpToken qiniu-token")
        XCTAssertTrue(completion.bodyString?.contains("\"partNumber\":1") == true)
        XCTAssertTrue(completion.bodyString?.contains("\"partNumber\":2") == true)
        XCTAssertTrue(completion.bodyString?.contains("\"partNumber\":3") == true)

        let cloudreveRequests = requests.filter { $0.url.path.hasPrefix("/api/v4/") }
        XCTAssertTrue(cloudreveRequests.allSatisfy { $0.authorization == "Bearer unit-token" })
    }

    func testUpyunAsyncUploadUsesSingleMultipartFileAndDoesNotCallCompletionEndpoint() async throws {
        let fixture = try UploadWireFixture(provider: "upyun", chunkSize: 4)
        defer { fixture.cleanup() }
        let sourceContents = Data("upyun-payload".utf8)
        let source = try fixture.makeSource(sourceContents)
        let protocolState = UploadWireURLProtocol.State(provider: "upyun", sourceSize: sourceContents.count)
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)
        let context = fixture.makeContext(itemIdentifier: fixture.template.itemIdentifier)

        let result = try await backend!.create(
            CreateRequest(template: fixture.template, contents: source, replayKey: "wire-upyun"),
            context: context
        )
        backend = nil

        XCTAssertEqual(result.remoteID, "remote-wire-upyun")
        let requests = protocolState.requests
        let upload = try XCTUnwrap(requests.first { $0.url.path == "/upyun/form" })
        XCTAssertEqual(upload.method, "POST")
        XCTAssertTrue(upload.contentType?.hasPrefix("multipart/form-data; boundary=") == true)
        XCTAssertNil(upload.authorization)
        XCTAssertTrue(upload.bodyString?.contains("name=\"policy\"") == true)
        XCTAssertTrue(upload.bodyString?.contains("upyun-policy") == true)
        XCTAssertTrue(upload.bodyString?.contains("name=\"authorization\"") == true)
        XCTAssertTrue(upload.bodyString?.contains("upyun-authorization") == true)
        XCTAssertTrue(upload.bodyString?.contains("name=\"content-type\"") == true)
        XCTAssertTrue(upload.bodyString?.contains("text/plain") == true)
        XCTAssertTrue(upload.body?.range(of: sourceContents) != nil)
        XCTAssertNil(requests.first { $0.url.path == "/upyun/complete" })
    }

    func testUpyunMultipartMimeValueFallsBackWhenItContainsControlCharacters() throws {
        let fixture = try UploadWireFixture(provider: "upyun", chunkSize: 4)
        defer { fixture.cleanup() }
        let source = try fixture.makeSource(Data("payload".utf8))
        let protocolState = UploadWireURLProtocol.State(provider: "upyun", sourceSize: 7, mimeType: "text/plain\r\nX-Injected: true")
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)

        _ = try backend!.create(template: fixture.template, content: Data("payload".utf8), replayKey: "wire-upyun-sync")
        backend = nil

        let upload = try XCTUnwrap(protocolState.requests.first { $0.url.path == "/upyun/form" })
        XCTAssertTrue(upload.bodyString?.contains("Content-Type: application/octet-stream") == true)
        XCTAssertFalse(upload.bodyString?.contains("X-Injected") == true)
        _ = source
    }

    func testCloudreveRemoteAsyncUploadUsesZeroBasedChunkQueryAndOpaqueCredential() async throws {
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: 4)
        defer { fixture.cleanup() }
        let source = try fixture.makeSource(Data("0123456789".utf8))
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10)
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)
        let context = fixture.makeContext(itemIdentifier: fixture.template.itemIdentifier)

        let result = try await backend!.create(
            CreateRequest(template: fixture.template, contents: source, replayKey: "wire-remote"),
            context: context
        )
        backend = nil

        XCTAssertEqual(result.remoteID, "remote-wire-remote")
        let remoteRequests = protocolState.requests.filter { $0.url.path == "/remote/upload" }
        XCTAssertEqual(remoteRequests.count, 3)
        XCTAssertEqual(remoteRequests.map { $0.url.query?.split(separator: "&").last.map(String.init) }, ["chunk=0", "chunk=1", "chunk=2"])
        XCTAssertEqual(remoteRequests.map(\.body), [Data("0123".utf8), Data("4567".utf8), Data("89".utf8)])
        XCTAssertTrue(remoteRequests.allSatisfy { $0.authorization == "remote-token" })
        XCTAssertTrue(remoteRequests.allSatisfy { $0.authorization?.hasPrefix("Bearer ") == false })
    }

    /// Local storage policies commonly chunk at 25 MiB; an 8 MiB client ceiling rejected every
    /// upload before a byte was sent.
    func testCloudreveChunkSizeAboveEightMiBIsAccepted() async throws {
        let chunkSize: Int64 = 25 * 1024 * 1024
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: chunkSize)
        defer { fixture.cleanup() }
        let source = try fixture.makeSource(Data("0123456789".utf8))
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10, chunkSize: chunkSize)
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)
        let result = try await backend!.create(
            CreateRequest(template: fixture.template, contents: source, replayKey: "wire-large-chunk"),
            context: fixture.makeContext(itemIdentifier: fixture.template.itemIdentifier)
        )
        backend = nil

        XCTAssertEqual(result.remoteID, "remote-wire-remote")
        XCTAssertEqual(protocolState.requests.filter { $0.url.path == "/remote/upload" }.map(\.body), [Data("0123456789".utf8)])
        XCTAssertFalse(protocolState.requests.contains { $0.method == "DELETE" })
    }

    /// A session the client refuses still exists on the server, with a placeholder file that
    /// makes every retry fail with 40004 until Cloudreve expires it. It must be cancelled.
    func testRejectedUploadSessionIsCancelledOnServer() async throws {
        let chunkSize: Int64 = 2 << 30
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: chunkSize)
        defer { fixture.cleanup() }
        let source = try fixture.makeSource(Data("0123456789".utf8))
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10, chunkSize: chunkSize)
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)
        do {
            _ = try await backend!.create(
                CreateRequest(template: fixture.template, contents: source, replayKey: "wire-rejected"),
                context: fixture.makeContext(itemIdentifier: fixture.template.itemIdentifier)
            )
            XCTFail("an out-of-range chunk size must be refused")
        } catch let failure as CoreFailure {
            XCTAssertEqual(failure.redactedContext["stage"], "chunk_size")
        }
        backend = nil

        let sessionCalls = protocolState.requests.filter { $0.url.path == "/api/v4/file/upload" }
        XCTAssertEqual(sessionCalls.map(\.method), ["PUT", "DELETE"])
        let cancel = try XCTUnwrap(sessionCalls.last?.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(cancel["id"] as? String, "session-remote-1")
        XCTAssertEqual((cancel["uri"] as? String)?.hasSuffix("payload.bin"), true)
        XCTAssertTrue(protocolState.requests.filter { $0.url.path == "/remote/upload" }.isEmpty)
    }

    /// Earlier builds wrote a session's credentials, then failed before recording the session.
    /// The retry of the same item and content finds those credentials under its operation's
    /// reference and cancels the orphan before asking for a new session.
    func testRetryCancelsSessionAnEarlierAttemptNeverRecorded() async throws {
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: 4)
        defer { fixture.cleanup() }
        let source = try fixture.makeSource(Data("0123456789".utf8))
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10)
        protocolState.storageStatus = 500
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)
        do {
            _ = try await backend!.create(
                CreateRequest(template: fixture.template, contents: source, replayKey: "wire-orphan"),
                context: fixture.makeContext(itemIdentifier: fixture.template.itemIdentifier)
            )
            XCTFail("the storage endpoint is failing")
        } catch {}
        backend = nil
        XCTAssertFalse(protocolState.requests.contains { $0.method == "DELETE" }, "a transient failure keeps the session so the upload can resume")

        try fixture.resetStore()
        protocolState.storageStatus = 200
        backend = fixture.makeBackend(protocolState: protocolState)
        let result = try await backend!.create(
            CreateRequest(template: fixture.template, contents: source, replayKey: "wire-orphan"),
            context: fixture.makeContext(itemIdentifier: fixture.template.itemIdentifier)
        )
        backend = nil

        XCTAssertEqual(result.remoteID, "remote-wire-remote")
        let sessionCalls = protocolState.requests.filter { $0.url.path == "/api/v4/file/upload" }
        XCTAssertEqual(sessionCalls.map(\.method), ["PUT", "DELETE", "PUT"])
        let cancel = try XCTUnwrap(sessionCalls[1].body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(cancel["id"] as? String, "session-remote-1")
    }

    /// A session kept for resuming an interrupted upload belongs to the old content. When the
    /// user saves again, the new upload must abandon it and cancel it on the server before
    /// asking for a new session, or Cloudreve refuses the new one with 40004 for about a day.
    func testChangedContentSupersedesSessionKeptForEarlierContent() async throws {
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: 4)
        defer { fixture.cleanup() }
        let firstSource = try fixture.makeSource(Data("0123456789".utf8))
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10)
        protocolState.storageStatus = 500
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)
        do {
            _ = try await backend!.create(
                CreateRequest(template: fixture.template, contents: firstSource, replayKey: "wire-supersede-a"),
                context: fixture.makeContext(itemIdentifier: fixture.template.itemIdentifier)
            )
            XCTFail("the storage endpoint is failing")
        } catch {}
        backend = nil
        let store = try SQLiteStateStore(url: fixture.storeURL)
        let kept = try XCTUnwrap(store.supersededUploadSessions(itemIdentifier: fixture.template.itemIdentifier, currentOperationID: UUID()).first)
        XCTAssertEqual(kept.state, "active")
        XCTAssertEqual(kept.remoteSessionReference, "session-remote-1")
        let keptSecret = try XCTUnwrap(kept.secretReference)
        XCTAssertNotNil(try fixture.secretVault.readSecret(reference: keptSecret))

        protocolState.storageStatus = 200
        let secondSource = try fixture.makeSource(Data("abcdefghij".utf8))
        backend = fixture.makeBackend(protocolState: protocolState)
        let result = try await backend!.create(
            CreateRequest(template: fixture.template, contents: secondSource, replayKey: "wire-supersede-b"),
            context: fixture.makeContext(itemIdentifier: fixture.template.itemIdentifier)
        )
        backend = nil

        XCTAssertEqual(result.remoteID, "remote-wire-remote")
        let sessionCalls = protocolState.requests.filter { $0.url.path == "/api/v4/file/upload" }
        XCTAssertEqual(sessionCalls.map(\.method), ["PUT", "DELETE", "PUT"])
        let cancel = try XCTUnwrap(sessionCalls[1].body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(cancel["id"] as? String, "session-remote-1")
        XCTAssertEqual(try store.uploadSession(operationID: kept.operationID)?.state, "abandoned")
        XCTAssertNil(try store.uploadSession(operationID: kept.operationID)?.secretReference)
        XCTAssertNil(try fixture.secretVault.readSecret(reference: keptSecret))
        XCTAssertEqual(protocolState.requests.filter { $0.url.path == "/remote/upload" }.suffix(3).map(\.body), [Data("abcd".utf8), Data("efgh".utf8), Data("ij".utf8)])
    }

    func testChangedContentDoesNotCancelSessionKeptForAnotherItem() async throws {
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: 4)
        defer { fixture.cleanup() }
        let other = try fixture.makeTemplate(name: "other.bin")
        let otherSource = try fixture.makeSource(Data("0123456789".utf8))
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10)
        protocolState.storageStatus = 500
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)
        do {
            _ = try await backend!.create(
                CreateRequest(template: other, contents: otherSource, replayKey: "wire-other-item"),
                context: fixture.makeContext(itemIdentifier: other.itemIdentifier)
            )
            XCTFail("the storage endpoint is failing")
        } catch {}
        backend = nil
        let store = try SQLiteStateStore(url: fixture.storeURL)
        let kept = try XCTUnwrap(store.supersededUploadSessions(itemIdentifier: other.itemIdentifier, currentOperationID: UUID()).first)

        protocolState.storageStatus = 200
        let source = try fixture.makeSource(Data("abcdefghij".utf8))
        backend = fixture.makeBackend(protocolState: protocolState)
        _ = try await backend!.create(
            CreateRequest(template: fixture.template, contents: source, replayKey: "wire-this-item"),
            context: fixture.makeContext(itemIdentifier: fixture.template.itemIdentifier)
        )
        backend = nil

        XCTAssertFalse(protocolState.requests.contains { $0.method == "DELETE" })
        let stillKept = try XCTUnwrap(store.uploadSession(operationID: kept.operationID))
        XCTAssertEqual(stillKept.state, "active")
        XCTAssertNotNil(try fixture.secretVault.readSecret(reference: try XCTUnwrap(stillKept.secretReference)))
    }

    /// Bytes of a verifying or completed session already landed; cancelling it could remove the
    /// real file, so a new upload of the same item leaves it alone.
    func testChangedContentDoesNotCancelVerifyingOrCompletedSessionOfSameItem() async throws {
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: 4)
        defer { fixture.cleanup() }
        let store = try SQLiteStateStore(url: fixture.storeURL)
        var seeded: [UploadSessionCheckpoint] = []
        for state in ["verifying", "completed"] {
            let reference = "transfer-seeded-\(state)"
            try fixture.secretVault.writeSecret("opaque", reference: reference)
            let session = UploadSessionCheckpoint(operationID: UUID(), remoteSessionReference: "session-seeded-\(state)", secretReference: reference, fingerprint: Data(state.utf8), provider: "remote", chunkSize: 4, expiresAt: Date().addingTimeInterval(3_600), state: state, itemIdentifier: fixture.template.itemIdentifier)
            try store.saveUploadSession(session)
            seeded.append(session)
        }
        let source = try fixture.makeSource(Data("0123456789".utf8))
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10)
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)
        _ = try await backend!.create(
            CreateRequest(template: fixture.template, contents: source, replayKey: "wire-landed"),
            context: fixture.makeContext(itemIdentifier: fixture.template.itemIdentifier)
        )
        backend = nil

        XCTAssertFalse(protocolState.requests.contains { $0.method == "DELETE" })
        for session in seeded {
            XCTAssertEqual(try store.uploadSession(operationID: session.operationID)?.state, session.state)
            XCTAssertNotNil(try fixture.secretVault.readSecret(reference: try XCTUnwrap(session.secretReference)))
        }
    }

    /// A retry with the same content resumes its own session; nothing is cancelled.
    func testSameContentRetryResumesItsOwnSessionWithoutCancelling() async throws {
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: 4)
        defer { fixture.cleanup() }
        let source = try fixture.makeSource(Data("0123456789".utf8))
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10)
        protocolState.storageStatus = 500
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)
        do {
            _ = try await backend!.create(
                CreateRequest(template: fixture.template, contents: source, replayKey: "wire-same-content"),
                context: fixture.makeContext(itemIdentifier: fixture.template.itemIdentifier)
            )
            XCTFail("the storage endpoint is failing")
        } catch {}
        backend = nil
        let store = try SQLiteStateStore(url: fixture.storeURL)
        let kept = try XCTUnwrap(store.supersededUploadSessions(itemIdentifier: fixture.template.itemIdentifier, currentOperationID: UUID()).first)

        protocolState.storageStatus = 200
        backend = fixture.makeBackend(protocolState: protocolState)
        let result = try await backend!.create(
            CreateRequest(template: fixture.template, contents: source, replayKey: "wire-same-content"),
            context: fixture.makeContext(itemIdentifier: fixture.template.itemIdentifier)
        )
        backend = nil

        XCTAssertEqual(result.remoteID, "remote-wire-remote")
        XCTAssertEqual(protocolState.requests.filter { $0.url.path == "/api/v4/file/upload" }.map(\.method), ["PUT"])
        XCTAssertFalse(protocolState.requests.contains { $0.method == "DELETE" })
        XCTAssertEqual(try store.uploadSession(operationID: kept.operationID)?.state, "completed")
    }

    /// Cloudreve answers 40004 (Object Already Exists) when a new file's name is taken; the
    /// system must see a filename collision, not a sync failure.
    func testUploadSessionObjectExistsOnCreateIsNameCollision() async throws {
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: 4)
        defer { fixture.cleanup() }
        let source = try fixture.makeSource(Data("0123456789".utf8))
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10)
        protocolState.uploadSessionAPICode = 40004
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)
        do {
            _ = try await backend!.create(
                CreateRequest(template: fixture.template, contents: source, replayKey: "wire-exists"),
                context: fixture.makeContext(itemIdentifier: fixture.template.itemIdentifier)
            )
            XCTFail("a taken name must be refused")
        } catch let failure as CoreFailure {
            XCTAssertEqual(failure.code, .nameCollision)
            XCTAssertFalse(failure.retryable)
            XCTAssertEqual(FileProviderErrorMapper.map(failure).code, NSFileProviderError.filenameCollision.rawValue)
        }
        backend = nil
    }

    /// Cloudreve answers 40076 (Current Version is Stale) when `previous` is no longer current;
    /// that is a version conflict so the conflict-copy recovery can run.
    func testContentModifyStaleVersionIsVersionConflict() async throws {
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: 4)
        defer { fixture.cleanup() }
        let existing = try fixture.storeExistingFile()
        let source = try fixture.makeSource(Data("0123456789".utf8))
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10)
        protocolState.uploadSessionAPICode = 40076
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)
        do {
            _ = try await backend!.modify(
                ModifyRequest(item: existing, expectedVersion: existing.version.content, changedFields: [.contents], contents: source, options: [], replayKey: "wire-stale"),
                context: fixture.makeContext(itemIdentifier: existing.itemIdentifier)
            )
            XCTFail("a stale previous version must be refused")
        } catch let failure as CoreFailure {
            XCTAssertEqual(failure.code, .versionConflict)
            XCTAssertFalse(failure.retryable)
        }
        backend = nil
        let body = try XCTUnwrap(protocolState.requests.first { $0.url.path == "/api/v4/file/upload" && $0.method == "PUT" }?.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["previous"] as? String, existing.remoteVersion)
    }

    /// An in-place version upload keeps the item's name, so 40004 there must not surface as a
    /// filename collision (the system would rename the user's file).
    func testContentModifyObjectExistsIsNotNameCollision() async throws {
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: 4)
        defer { fixture.cleanup() }
        let existing = try fixture.storeExistingFile()
        let source = try fixture.makeSource(Data("0123456789".utf8))
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10)
        protocolState.uploadSessionAPICode = 40004
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)
        do {
            _ = try await backend!.modify(
                ModifyRequest(item: existing, expectedVersion: existing.version.content, changedFields: [.contents], contents: source, options: [], replayKey: "wire-modify-exists"),
                context: fixture.makeContext(itemIdentifier: existing.itemIdentifier)
            )
            XCTFail("the upload session was refused")
        } catch let failure as CoreFailure {
            XCTAssertNotEqual(failure.code, .nameCollision)
            XCTAssertEqual(failure.code, .unknownOutcome)
            XCTAssertFalse(failure.retryable)
        }
        backend = nil
    }
}

private final class DirectoryPageWireURLProtocol: URLProtocol {
    enum Mode: Sendable {
        case page
        case cursor
    }

    final class State: @unchecked Sendable {
        let mode: Mode
        /// Extra entries served on the first page after the regular one.
        let extraFiles: [[String: Any]]
        private let lock = NSLock()
        private var queries: [String] = []

        init(mode: Mode, extraFiles: [[String: Any]] = []) {
            self.mode = mode
            self.extraFiles = extraFiles
        }

        var requestedQueries: [String] {
            lock.lock()
            defer { lock.unlock() }
            return queries
        }

        func append(query: String) {
            lock.lock()
            queries.append(query)
            lock.unlock()
        }
    }

    private final class StateBox: @unchecked Sendable {
        let lock = NSLock()
        var value: State?
    }

    private static let stateBox = StateBox()

    static func install(_ state: State) {
        stateBox.lock.lock()
        stateBox.value = state
        stateBox.lock.unlock()
    }

    static func clear() {
        stateBox.lock.lock()
        stateBox.value = nil
        stateBox.lock.unlock()
    }

    private static func state() -> State? {
        stateBox.lock.lock()
        defer { stateBox.lock.unlock() }
        return stateBox.value
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "cloudreve.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let state = Self.state() else {
            client?.urlProtocol(self, didFailWithError: WireTestError.cannotCreateSource)
            return
        }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let cursor = queryItems.first(where: { $0.name == "next_page_token" })?.value
        let page = queryItems.first(where: { $0.name == "page" })?.value.flatMap(Int.init) ?? (cursor == nil ? 1 : 2)
        state.append(query: cursor.map { "next_page_token=\($0)" } ?? "page=\(page)")
        var pagination: [String: Any] = ["page": page, "page_size": 1, "total_items": 2]
        if state.mode == .cursor, cursor == nil {
            pagination["next_token"] = "cursor-1"
        }
        let body: [String: Any] = [
            "code": 0,
            "data": [
                "files": (page == 1 ? state.extraFiles : []) + [[
                    "type": 0,
                    "id": "remote-page-\(page)",
                    "name": "page-\(page).txt",
                    "created_at": "2026-09-07T00:00:00Z",
                    "updated_at": "2026-09-07T00:00:00Z",
                    "size": page,
                    "path": "/page-\(page).txt",
                    "permission": "r",
                    "capability": "r",
                    "primary_entity": "entity-\(page)"
                ] as [String: Any]],
                "pagination": pagination
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class UploadWireFixture {
    let provider: String
    let chunkSize: Int64
    let allowsPurge: Bool
    let storeURL: URL
    let rootURI: String
    let domainIdentifier: String
    let template: RemoteItem
    let credentialVault: MemoryCredentialVault
    let secretVault: MemoryOpaqueSecretVault
    private var sourceURLs: [URL] = []

    init(provider: String, chunkSize: Int64, allowsPurge: Bool = false) throws {
        self.provider = provider
        self.chunkSize = chunkSize
        self.allowsPurge = allowsPurge
        self.storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-wire-\(provider)-\(UUID().uuidString).sqlite3")
        self.rootURI = try CloudreveRemoteURI.canonical("/", accountID: "account")
        self.domainIdentifier = CloudreveIdentifier.domain()
        self.template = RemoteItem(
            itemIdentifier: CloudreveIdentifier.item(),
            remoteID: nil,
            parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
            name: "payload.bin",
            uri: try CloudreveRemoteURI.append(rootURI, name: "payload.bin"),
            kind: .file,
            contentType: "public.data",
            size: 0,
            version: ItemVersion(content: Data("template".utf8), metadata: Data("template".utf8)),
            canRead: true,
            canWrite: true
        )
        self.credentialVault = MemoryCredentialVault()
        self.secretVault = MemoryOpaqueSecretVault()
        let store = try SQLiteStateStore(url: storeURL)
        let capabilities = Self.capabilities(provider: provider, allowsPurge: allowsPurge)
        let scope = try RemoteScope(origin: "https://cloudreve.example", accountID: "account", rootURI: rootURI)
        try store.registerDomain(DomainDescriptor(identifier: domainIdentifier, displayName: "Wire Test", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential", capabilitySnapshot: capabilities))
        try credentialVault.write(Credential(accessToken: "unit-token", refreshToken: "refresh-token", accessExpiry: Date().addingTimeInterval(3_600)), reference: "credential")
    }

    /// Swaps in an empty state store for the same domain while keeping the secret vault: what an
    /// earlier build left behind when it created a server session but never recorded it.
    func resetStore() throws {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
        let store = try SQLiteStateStore(url: storeURL)
        let scope = try RemoteScope(origin: "https://cloudreve.example", accountID: "account", rootURI: rootURI)
        try store.registerDomain(DomainDescriptor(identifier: domainIdentifier, displayName: "Wire Test", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential", capabilitySnapshot: Self.capabilities(provider: provider, allowsPurge: allowsPurge)))
    }

    /// Another new file in the root, so tests can tell sessions of different items apart.
    func makeTemplate(name: String) throws -> RemoteItem {
        RemoteItem(
            itemIdentifier: CloudreveIdentifier.item(),
            remoteID: nil,
            parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
            name: name,
            uri: try CloudreveRemoteURI.append(rootURI, name: name),
            kind: .file,
            contentType: "public.data",
            size: 0,
            version: ItemVersion(content: Data("template".utf8), metadata: Data("template".utf8)),
            canRead: true,
            canWrite: true
        )
    }

    /// Records the template as an existing remote file so a content modify has a `previous` version.
    func storeExistingFile() throws -> RemoteItem {
        var existing = template
        existing.remoteID = "remote-wire-\(provider)"
        existing.remoteVersion = "entity-\(provider)"
        try SQLiteStateStore(url: storeURL).insertItem(existing)
        return existing
    }

    func makeSource(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-wire-source-\(UUID().uuidString).bin")
        guard FileManager.default.createFile(atPath: url.path, contents: data) else { throw WireTestError.cannotCreateSource }
        sourceURLs.append(url)
        return url
    }

    func makeBackend(protocolState: UploadWireURLProtocol.State) -> NimbusSyncRemoteBackend {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadWireURLProtocol.self]
        UploadWireURLProtocol.install(protocolState)
        let store = try! SQLiteStateStore(url: storeURL)
        return NimbusSyncRemoteBackend(
            origin: URL(string: "https://cloudreve.example")!,
            rootURI: rootURI,
            store: store,
            vault: credentialVault,
            credentialReference: "credential",
            capabilitySnapshot: Self.capabilities(provider: provider, allowsPurge: allowsPurge),
            providerName: provider,
            secretVault: secretVault,
            requestTimeout: 10,
            clientID: "wire-client",
            domainIdentifier: domainIdentifier,
            urlSessionConfiguration: configuration
        )
    }

    func makeContext(itemIdentifier: String) -> FileProviderOperationContext {
        FileProviderOperationContext(itemIdentifier: NSFileProviderItemIdentifier(itemIdentifier), progress: Progress(totalUnitCount: 1), registrar: NoopURLSessionTaskRegistrar(), cancellation: CancellationToken())
    }

    func cleanup() {
        UploadWireURLProtocol.clear()
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        try? FileManager.default.removeItem(at: storeURL)
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: storeURL.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try? FileManager.default.removeItem(at: sidecar)
            }
        }
        for sourceURL in sourceURLs {
            try? FileManager.default.removeItem(at: sourceURL)
        }
        sourceURLs.removeAll()
    }

    private static func capabilities(provider: String, allowsPurge: Bool) -> CapabilitySnapshot {
        let providerCapability = CapabilitySnapshot.Provider(name: provider, read: .verified, write: .verified, resumable: .verified, zeroByte: .verified, crypto: .verified)
        let operations = CapabilitySnapshot.OperationCapabilities(collisionSafeCreate: .verified, conditionalModify: .verified, metadataMove: .verified, trash: .verified, purge: allowsPurge ? .verified : .unsupported, zeroByte: .verified, resumable: .verified)
        return CapabilitySnapshot(
            revision: 1,
            stableItemIdentity: .verified,
            stableRootIdentity: .verified,
            conditionalContentWrite: .verified,
            conditionalMetadataMutation: .verified,
            idempotentCreate: .verified,
            contentVersionSemantics: .verified,
            resumableUploadProviders: [provider],
            uploadCompletionQueryableProviders: [provider],
            zeroByteWriteProviders: [provider],
            resolvedUploadPolicyKinds: [provider],
            deleteSemantics: allowsPurge ? .verified : .unsupported,
            trashRestore: .verified,
            providers: [providerCapability],
            operations: operations
        )
    }
}

private enum WireTestError: Error {
    case cannotCreateSource
}

private final class UploadWireURLProtocol: URLProtocol {
    struct Request: Sendable {
        let url: URL
        let method: String
        let authorization: String?
        let contentType: String?
        let body: Data?

        var bodyString: String? { body.flatMap { String(data: $0, encoding: .utf8) } }
    }

    final class State: @unchecked Sendable {
        let provider: String
        let sourceSize: Int
        let mimeType: String
        let chunkSize: Int64
        private let lock = NSLock()
        private var recordedRequests: [Request] = []
        private var sessionsCreated = 0
        private var storageStatusValue = 200
        private var uploadSessionAPICodeValue: Int?
        private var fileInfoAPICodeValue: Int?

        init(provider: String, sourceSize: Int, mimeType: String = "text/plain", chunkSize: Int64 = 4) {
            self.provider = provider
            self.sourceSize = sourceSize
            self.mimeType = mimeType
            self.chunkSize = chunkSize
        }

        /// HTTP status the storage endpoint answers with; 500 simulates a transient failure.
        var storageStatus: Int {
            get { lock.lock(); defer { lock.unlock() }; return storageStatusValue }
            set { lock.lock(); storageStatusValue = newValue; lock.unlock() }
        }

        /// Cloudreve envelope code `PUT file/upload` answers with instead of a session; nil serves a session.
        var uploadSessionAPICode: Int? {
            get { lock.lock(); defer { lock.unlock() }; return uploadSessionAPICodeValue }
            set { lock.lock(); uploadSessionAPICodeValue = newValue; lock.unlock() }
        }

        /// Cloudreve envelope code `file/info` answers with instead of the file; nil serves the file.
        var fileInfoAPICode: Int? {
            get { lock.lock(); defer { lock.unlock() }; return fileInfoAPICodeValue }
            set { lock.lock(); fileInfoAPICodeValue = newValue; lock.unlock() }
        }

        /// Each `PUT file/upload` gets its own session ID so tests can tell which one was cancelled.
        func nextSessionID() -> String {
            lock.lock()
            defer { lock.unlock() }
            sessionsCreated += 1
            return "session-\(provider)-\(sessionsCreated)"
        }

        var requests: [Request] {
            lock.lock()
            defer { lock.unlock() }
            return recordedRequests
        }

        func append(_ request: Request) {
            lock.lock()
            recordedRequests.append(request)
            lock.unlock()
        }
    }

    private final class StateBox: @unchecked Sendable {
        let lock = NSLock()
        var value: State?
    }

    private static let stateBox = StateBox()

    static func install(_ state: State) {
        stateBox.lock.lock()
        stateBox.value = state
        stateBox.lock.unlock()
    }

    static func clear() {
        stateBox.lock.lock()
        stateBox.value = nil
        stateBox.lock.unlock()
    }

    private static func currentState() -> State? {
        stateBox.lock.lock()
        defer { stateBox.lock.unlock() }
        return stateBox.value
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "cloudreve.example" || request.url?.host == "storage.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let requestURL = request.url, let state = Self.currentState() else {
            client?.urlProtocol(self, didFailWithError: WireTestError.cannotCreateSource)
            return
        }
        let body = Self.body(from: request)
        state.append(Request(url: requestURL, method: request.httpMethod ?? "GET", authorization: request.value(forHTTPHeaderField: "Authorization"), contentType: request.value(forHTTPHeaderField: "Content-Type"), body: body))
        let responseBody: Data
        let statusCode: Int
        if requestURL.host == "storage.example" {
            (statusCode, responseBody) = Self.storageResponse(for: request, state: state)
        } else {
            (statusCode, responseBody) = Self.cloudreveResponse(for: request, state: state)
        }
        let response = HTTPURLResponse(url: requestURL, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !responseBody.isEmpty { client?.urlProtocol(self, didLoad: responseBody) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(from request: URLRequest) -> Data? {
        if let httpBody = request.httpBody { return httpBody }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var body = Data()
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }

    private static func cloudreveResponse(for request: URLRequest, state: State) -> (Int, Data) {
        let path = request.url?.path ?? ""
        if path == "/api/v4/file/upload", request.httpMethod == "DELETE" {
            return (200, Data(#"{"code":0}"#.utf8))
        }
        if path == "/api/v4/file", request.httpMethod == "DELETE" {
            return (200, Data(#"{"code":0}"#.utf8))
        }
        if path == "/api/v4/file/move" {
            return (200, Data(#"{"code":0}"#.utf8))
        }
        if path == "/api/v4/file/upload", let code = state.uploadSessionAPICode {
            return (200, Data("{\"code\":\(code),\"msg\":\"rejected\"}".utf8))
        }
        if path == "/api/v4/file/upload" {
            let uploadURL: String
            switch state.provider {
            case "qiniu": uploadURL = "https://storage.example/qiniu/upload"
            case "upyun": uploadURL = "https://storage.example/upyun/form"
            default: uploadURL = "https://storage.example/remote/upload?session=opaque"
            }
            let credential: String
            switch state.provider {
            case "qiniu": credential = "qiniu-token"
            case "upyun": credential = "upyun-authorization"
            default: credential = "remote-token"
            }
            let policy: [String: Any] = [
                "code": 0,
                "data": [
                    "session_id": state.nextSessionID(),
                    "expires": Int(Date().addingTimeInterval(3_600).timeIntervalSince1970),
                    "chunk_size": state.chunkSize,
                    "credential": credential,
                    "upload_policy": state.provider == "upyun" ? "upyun-policy" : NSNull(),
                    "mime_type": state.mimeType,
                    "upload_urls": [uploadURL],
                    "callback_secret": NSNull(),
                    "completeURL": NSNull(),
                    "storage_policy": ["type": state.provider]
                ]
            ]
            return (200, try! JSONSerialization.data(withJSONObject: policy))
        }
        if path == "/api/v4/file/info", let code = state.fileInfoAPICode {
            return (200, Data("{\"code\":\(code),\"msg\":\"not found\"}".utf8))
        }
        if path == "/api/v4/file/info" {
            let response: [String: Any] = [
                "code": 0,
                "data": [
                    "type": 0,
                    "id": "remote-wire-\(state.provider)",
                    "name": "payload.bin",
                    "created_at": "2026-09-05T00:00:00Z",
                    "updated_at": "2026-09-05T00:00:00Z",
                    "size": state.sourceSize,
                    "path": "/payload.bin",
                    "permission": "r",
                    "capability": "rwd",
                    "primary_entity": "entity-\(state.provider)"
                ]
            ]
            return (200, try! JSONSerialization.data(withJSONObject: response))
        }
        return (404, Data())
    }

    private static func storageResponse(for request: URLRequest, state: State) -> (Int, Data) {
        let path = request.url?.path ?? ""
        if state.provider == "qiniu", path.hasPrefix("/qiniu/upload/") {
            let number = path.split(separator: "/").last ?? "0"
            return (200, Data("{\"etag\":\"etag-\(number)\"}".utf8))
        }
        if state.provider == "qiniu", path == "/qiniu/upload" {
            return (200, Data())
        }
        if state.provider == "upyun", path == "/upyun/form" {
            return (204, Data())
        }
        if state.provider == "remote", path == "/remote/upload" {
            let status = state.storageStatus
            return (status, status == 200 ? Data(#"{"code":0}"#.utf8) : Data())
        }
        return (404, Data())
    }
}
