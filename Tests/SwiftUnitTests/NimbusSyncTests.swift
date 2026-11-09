import XCTest
import Foundation
import CryptoKit
import FileProvider
import CSQLite
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveAuthKit
import CloudreveEventCoordinator
import CloudreveFileProviderKit
import CloudreveObservability
import CloudreveDomainService
import CloudreveProductKit

final class NimbusSyncTests: XCTestCase {
    func testOpaqueIdentifiersAndScopeOverlap() throws {
        let domainID = CloudreveIdentifier.domain()
        XCTAssertTrue(CloudreveIdentifier.validate(domainID, prefix: CloudreveIdentifier.domainPrefix))
        XCTAssertFalse(CloudreveIdentifier.validate("crd-https://example.com", prefix: CloudreveIdentifier.domainPrefix))
        let root = try RemoteScope(origin: "https://example.com/", accountID: "account", rootURI: "/team")
        let child = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/team/docs")
        XCTAssertTrue(root.overlaps(child))
        XCTAssertEqual(root.origin, "https://example.com")
    }

    func testCloudreveRemoteURIKeepsFilesystemIdentityAndPath() throws {
        let root = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "cloudreve://account@my/team/")
        let child = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "cloudreve://account@my/team/docs")
        XCTAssertEqual(root.rootURI, "cloudreve://account@my/team")
        XCTAssertTrue(root.overlaps(child))
        XCTAssertEqual(try CloudreveRemoteURI.append(root.rootURI, name: "note.txt"), "cloudreve://account@my/team/note.txt")
        XCTAssertEqual(CloudreveRemoteURI.relativePath("cloudreve://account@my/team/docs/note.txt", root: root.rootURI), "docs/note.txt")
        let directChild = try CloudreveRemoteURI.append(root.rootURI, name: "direct.txt")
        XCTAssertEqual(CloudreveRemoteURI.parent(directChild), root.rootURI)
    }

    func testCloudreveRemoteScopeRejectsNonMyFilesystemURI() {
        XCTAssertThrowsError(try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "cloudreve://account@share/team"))
    }

    func testCloudreveRemoteURICanonicalizesServerPathsWithinAccountRoot() throws {
        let root = try RemoteScope(origin: "https://example.com", accountID: "W6UD", rootURI: "/sync-jorben/个人文件/Anna")
        let rawPath = "/sync-jorben/个人文件/Anna/0091_001.pdf"
        let canonical = try CloudreveRemoteURI.canonical(rawPath, accountID: "W6UD")
        XCTAssertEqual(canonical, "cloudreve://W6UD@my/sync-jorben/%E4%B8%AA%E4%BA%BA%E6%96%87%E4%BB%B6/Anna/0091_001.pdf")
        XCTAssertTrue(CloudreveRemoteURI.isWithin(canonical, root: root.rootURI))
    }

    func testProductSnapshotPreservesStoredDomainIdentifier() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-domain-identity-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let identifier = "crd-11111111-1111-4111-8111-111111111111"
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/team")
        let descriptor = DomainDescriptor(identifier: identifier, displayName: "Stable", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential-ref")
        try store.registerDomain(descriptor)
        let snapshot = await ProductStore(registry: store).snapshot()
        XCTAssertEqual(snapshot.domains.first?.identifier, identifier)
    }

    func testHealthReducerRequiresAnchorAndReconciliation() {
        var input = HealthInputs()
        input.authenticated = true; input.rootAvailable = true; input.scopeValid = true; input.appRunning = true; input.validAnchor = true
        XCTAssertEqual(DomainHealthReducer.reduce(input), .reconciling)
        input.recentlyReconciled = true
        XCTAssertEqual(DomainHealthReducer.reduce(input), .healthy)
        input.eventDegraded = true
        XCTAssertEqual(DomainHealthReducer.reduce(input), .eventDegraded)
        input.offline = true
        XCTAssertEqual(DomainHealthReducer.reduce(input), .offline)
    }

    func testPageTokenAndAnchorStayBounded() throws {
        let token = PageToken(domainIdentifier: CloudreveIdentifier.domain(), parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, snapshotGeneration: 3, offset: 10)
        XCTAssertLessThan(try token.encoded().count, 500)
        XCTAssertEqual(try PageToken.decode(token.encoded()), token)
        let anchor = SyncAnchor(domainIdentifier: token.domainIdentifier, scope: "working_set", epoch: UUID(), sequence: 20)
        XCTAssertLessThan(try anchor.encoded().count, 500)
        XCTAssertEqual(try SyncAnchor.decode(anchor.encoded()), anchor)
    }

    func testContinuationRejectsFutureAnchorAndUnboundDirectoryGeneration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-continuation-bounds-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let domainID = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: domainID, displayName: "Bounds", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential"))

        let current = try store.currentAnchor(domainIdentifier: domainID, scope: NSFileProviderItemIdentifier.rootContainer.rawValue)
        let future = SyncAnchor(domainIdentifier: domainID, scope: current.scope, epoch: current.epoch, sequence: current.sequence + 1)
        XCTAssertThrowsError(try store.enumerateChanges(domainIdentifier: domainID, scope: current.scope, from: future)) { error in
            XCTAssertEqual(error as? StoreBridgeError, .anchorExpired)
        }

        let unboundPage = PageToken(domainIdentifier: domainID, parentIdentifier: current.scope, snapshotGeneration: 0, offset: 0)
        XCTAssertThrowsError(try unboundPage.validate(domainIdentifier: domainID, parentIdentifier: current.scope))
    }

    func testSQLiteDirectoryPagesRemainBoundedAtTenThousandItems() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-page-\(UUID().uuidString).sqlite3")
        defer { if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) } }
        let store = try SQLiteStateStore(url: url)
        let items = (0..<10_000).map { index in
            RemoteItem(itemIdentifier: CloudreveIdentifier.item(), remoteID: "remote-\(index)", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: String(format: "item-%05d", index), uri: "/item-\(index)", kind: .file, contentType: "public.data", size: 0, version: ItemVersion(content: Data("v\(index)".utf8), metadata: Data("m\(index)".utf8)), canRead: true)
        }
        for item in items { try store.insertItem(item) }
        var offset = 0
        var count = 0
        while true {
            let page = try store.listChildrenPage(parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, offset: offset, limit: 127)
            count += page.items.count
            XCTAssertLessThanOrEqual(page.items.count, 127)
            if let next = page.nextOffset { offset = next } else { break }
        }
        XCTAssertEqual(count, 10_000)
    }

    func testDomainVersionIsPersistedAndMonotonic() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-domain-version-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let projection = DomainStateProjection(authenticated: true)
        let first = projection.domainVersion
        projection.advance(hasConflict: true)
        try projection.persist(to: url)
        let restored = DomainStateProjection.load(from: url, authenticated: true, hasConflict: true)
        XCTAssertGreaterThan(restored.domainVersion, first)
        XCTAssertEqual(restored.userInfo["hasConflict"] as? Bool, true)
    }

    func testSQLiteJournalAndOutboxAreRecoverable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-test-\(UUID().uuidString).sqlite3")
        defer {
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let store = try SQLiteStateStore(url: url)
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        let descriptor = DomainDescriptor(displayName: "Test", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential-ref")
        try store.registerDomain(descriptor)
        let item = RemoteItem(remoteID: "remote-journal", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "journal.txt", uri: "/journal.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true)
        try store.insertItem(item)
        let change = try store.appendProviderChange(itemIdentifier: item.itemIdentifier, oldParentIdentifier: nil, newParentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, kind: "created", version: Data("v1".utf8), origin: "remote")
        XCTAssertEqual(change.sequence, 1)
        XCTAssertEqual(try store.pendingOutboxCount(), 1)
        let anchor = try store.currentAnchor(domainIdentifier: descriptor.identifier, scope: NSFileProviderItemIdentifier.rootContainer.rawValue)
        let batch = try store.enumerateChanges(domainIdentifier: descriptor.identifier, scope: NSFileProviderItemIdentifier.rootContainer.rawValue, from: SyncAnchor(domainIdentifier: descriptor.identifier, scope: NSFileProviderItemIdentifier.rootContainer.rawValue, epoch: change.epoch, sequence: 0))
        XCTAssertEqual(batch.changes.count, 1)
        try store.acknowledgeOutbox(upTo: batch.changes[0].sequence)
        XCTAssertEqual(try store.pendingOutboxCount(), 0)
        XCTAssertTrue(try store.quickCheck())
        _ = anchor
    }

    func testWorkingSetJournalDeliversRemoteCreateAfterExistingAnchor() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-working-set-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let domainID = CloudreveIdentifier.domain()
        let remoteScope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: domainID, displayName: "Test", scope: remoteScope, rootRemoteID: "root", accountID: "account", secretReference: "credential-ref"))
        let scope = NSFileProviderItemIdentifier.workingSet.rawValue
        let before = try store.currentAnchor(domainIdentifier: domainID, scope: scope)
        let item = RemoteItem(itemIdentifier: CloudreveIdentifier.item(), remoteID: "remote-working-set", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "new-file.dmg", uri: "/new-file.dmg", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true)

        _ = try store.commitProviderChange(item: item, oldParentIdentifier: nil, newParentIdentifier: item.parentIdentifier, kind: "reconciled", origin: "reconciliation")

        XCTAssertEqual(before.epoch, try store.currentAnchor(domainIdentifier: domainID, scope: scope).epoch)
        let batch = try store.enumerateChanges(domainIdentifier: domainID, scope: scope, from: before)
        XCTAssertEqual(batch.changes.map(\.itemIdentifier), [item.itemIdentifier])
        XCTAssertEqual(batch.changes.first?.newParentIdentifier, item.parentIdentifier)
        XCTAssertEqual(batch.changes.first?.kind, "reconciled")
    }

    func testSignalOutboxRetainsRevisionUntilWorkingSetSignalSucceeds() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-signal-outbox-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let item = RemoteItem(itemIdentifier: CloudreveIdentifier.item(), remoteID: "remote-signal", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "signal.txt", uri: "/signal.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true)
        _ = try store.commitProviderChange(item: item, oldParentIdentifier: nil, newParentIdentifier: item.parentIdentifier, kind: "reconciled", origin: "reconciliation")

        let failing = RecordingWorkingSetSignaller(shouldFail: true)
        let failed = await SignalOutboxDrainer(store: store, signaller: failing).drain()
        XCTAssertFalse(failed)
        XCTAssertEqual(try store.pendingOutboxCount(), 1)

        let succeeding = RecordingWorkingSetSignaller(shouldFail: false)
        let drained = await SignalOutboxDrainer(store: store, signaller: succeeding).drain()
        XCTAssertTrue(drained)
        XCTAssertEqual(try store.pendingOutboxCount(), 0)
        let signalCalls = await succeeding.callCount()
        XCTAssertEqual(signalCalls, 1)
    }

    func testSSEParserHandlesCRLFCommentsAndMultilineData() throws {
        let parser = SSEParser(maxFrameBytes: 1024)
        let events = try parser.append(Data(": keep\r\nevent: file\r\nid: 3\r\ndata: one\r\ndata: two\r\n\r\n".utf8))
        XCTAssertEqual(events, [SSEEvent(event: "file", data: "one\ntwo", id: "3")])
    }

    func testSSEParserHandlesCRLFSplitAcrossChunks() throws {
        let parser = SSEParser(maxFrameBytes: 1024)
        XCTAssertTrue(try parser.append(Data("event: one\r".utf8)).isEmpty)
        XCTAssertEqual(try parser.append(Data("\ndata: first\r\n\r\n".utf8)), [SSEEvent(event: "one", data: "first", id: nil)])
    }

    func testOAuthStateIsSingleUse() throws {
        let coordinator = OAuthCoordinator()
        let state = coordinator.begin().state
        let url = URL(string: "cloudreve://mount?code=abc&state=\(state)&path=%2Fteam&user_id=account")!
        XCTAssertEqual(try coordinator.validate(url: url).code, "abc")
        XCTAssertEqual(try coordinator.validate(url: URL(string: "cloudreve://mount?code=abc&state=\(coordinator.begin().state)")!).path, "")
        XCTAssertThrowsError(try coordinator.validate(url: url))
        let oldSchemeURL = URL(string: "nimbussync://callback/desktop?code=abc&state=\(state)")!
        XCTAssertThrowsError(try coordinator.validate(url: oldSchemeURL))
        let compatibleState = coordinator.begin().state
        XCTAssertEqual(try coordinator.validate(url: URL(string: "cloudreve://callback/desktop?code=abc&state=\(compatibleState)")!).path, "/desktop")
        XCTAssertFalse(coordinator.pkceChallenge(verifier: "verifier").contains("="))
    }

    func testExternalBrowserOAuthAcceptsCloudreveCallbackAndCanCancel() async throws {
        let openedURL = LockedURLCapture()
        let session = await MainActor.run {
            OAuthAuthorizationSession(openURL: { url in openedURL.store(url); return true })
        }

        let authorization = Task { @MainActor in
            try await session.authorize(origin: URL(string: "https://cloudreve.example")!)
        }
        let authorizeURL = try await waitForCapturedURL(openedURL)
        let state = try XCTUnwrap(URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value)
        let callback = try XCTUnwrap(URL(string: "cloudreve://mount?code=abc&state=\(state)&path=%2Fteam"))
        let handled = await MainActor.run { session.receiveCallback(callback) }
        XCTAssertTrue(handled)
        let result = try await authorization.value
        XCTAssertEqual(result.callback.remotePath, "/team")

        openedURL.clear()
        let cancelledAuthorization = Task { @MainActor in
            try await session.authorize(origin: URL(string: "https://cloudreve.example")!)
        }
        _ = try await waitForCapturedURL(openedURL)
        await MainActor.run { session.cancel() }
        do {
            _ = try await cancelledAuthorization.value
            XCTFail("Expected authorization cancellation")
        } catch let error as OAuthAuthorizationSessionError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testConcurrentRefreshReusesCredentialWrittenByFirstOwner() async throws {
        let vault = MemoryCredentialVault()
        let initial = Credential(accessToken: "old", refreshToken: "refresh", accessExpiry: Date().addingTimeInterval(-60), generation: 1)
        let refreshed = Credential(accessToken: "new", refreshToken: "refresh-2", accessExpiry: Date().addingTimeInterval(3_600), generation: 2)
        try vault.write(initial, reference: "credential")
        let invocations = RefreshInvocationCounter()
        let coordinator = TokenRefreshCoordinator(vault: vault, leaseDuration: 1)
        async let first = coordinator.credential(reference: "credential") { _ in
            await invocations.increment()
            try await Task.sleep(for: .milliseconds(100))
            return refreshed
        }
        async let second = coordinator.credential(reference: "credential") { _ in
            await invocations.increment()
            return refreshed
        }
        _ = try await (first, second)
        let invocationCount = await invocations.value
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(try vault.read(reference: "credential")?.accessToken, "new")
    }

    func testFileProviderBackendRejectsStaleContent() throws {
        let item = RemoteItem(name: "file.txt", uri: "/file.txt", kind: .file, contentType: "public.data", size: 3, version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true, canWrite: true)
        let backend = MemoryFileProviderBackend(items: [item], contents: [item.itemIdentifier: Data("one".utf8)])
        XCTAssertThrowsError(try backend.content(identifier: item.itemIdentifier, expectedVersion: Data("old".utf8))) { error in
            XCTAssertEqual((error as? CoreFailure)?.code, .versionConflict)
        }
    }

    func testReplayCreateUsesStableTemplateIdentityAndOperationLease() throws {
        let first = CloudreveIdentifier.item(forTemplate: "template-42")
        let second = CloudreveIdentifier.item(forTemplate: "template-42")
        XCTAssertEqual(first, second)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-lease-\(UUID().uuidString).sqlite3")
        defer { if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) } }
        let store = try SQLiteStateStore(url: url)
        let operation = PendingOperation(replayKey: first, kind: "create", itemIdentifier: first)
        _ = try store.upsertOperation(operation)
        let owner = UUID()
        XCTAssertTrue(try store.acquireOperationLease(operationID: operation.operationID, owner: owner, now: Date(timeIntervalSince1970: 100), duration: 30))
        XCTAssertFalse(try store.acquireOperationLease(operationID: operation.operationID, owner: UUID(), now: Date(timeIntervalSince1970: 101), duration: 30))
        try store.releaseOperationLease(operationID: operation.operationID, owner: owner)
        XCTAssertTrue(try store.acquireOperationLease(operationID: operation.operationID, owner: UUID(), now: Date(timeIntervalSince1970: 101), duration: 30))
    }

    func testUploadSessionCheckpointPersistsOnlyOpaqueSecretReferenceAndParts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-upload-\(UUID().uuidString).sqlite3")
        defer { if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) } }
        let store = try SQLiteStateStore(url: url)
        let operationID = UUID()
        let session = UploadSessionCheckpoint(operationID: operationID, remoteSessionReference: "remote-session", secretReference: "keychain-ref", fingerprint: Data("fingerprint".utf8), provider: "s3", chunkSize: 4, expiresAt: Date().addingTimeInterval(600), parts: [UploadPartCheckpoint(index: 0, offset: 0, length: 4, sourceHash: Data("hash".utf8), etag: "etag", state: "completed")])
        try store.saveUploadSession(session)
        let restored = try XCTUnwrap(try store.uploadSession(operationID: operationID))
        XCTAssertEqual(restored.operationID, session.operationID)
        XCTAssertEqual(restored.remoteSessionReference, session.remoteSessionReference)
        XCTAssertEqual(restored.secretReference, session.secretReference)
        XCTAssertEqual(restored.fingerprint, session.fingerprint)
        XCTAssertEqual(restored.parts, session.parts)
        XCTAssertEqual(restored.expiresAt?.timeIntervalSince1970 ?? 0, floor(session.expiresAt?.timeIntervalSince1970 ?? 0), accuracy: 1)
    }

    func testMutationCoordinatorReplaysCommittedCreateWithoutDuplicate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-mutation-\(UUID().uuidString).sqlite3")
        defer { if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) } }
        let store = try SQLiteStateStore(url: url)
        let template = RemoteItem(itemIdentifier: CloudreveIdentifier.item(forTemplate: "template-create"), parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "note.txt", uri: "/note.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data(), metadata: Data()), canRead: true, canWrite: true)
        let backend = MemoryFileProviderBackend()
        let coordinator = FileProviderMutationCoordinator(store: store, backend: backend)
        let first = try coordinator.create(template: template, content: Data("hello".utf8), fields: [.contents, .filename], options: [])
        let second = try coordinator.create(template: template, content: Data("hello".utf8), fields: [.contents, .filename], options: [])
        XCTAssertEqual(first.itemIdentifier, second.itemIdentifier)
        XCTAssertEqual(try backend.children(parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue).count, 1)
    }

    func testMutationCoordinatorRejectsStaleModifyAndNonRecursiveDirectoryDelete() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-mutation-stale-\(UUID().uuidString).sqlite3")
        defer { if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) } }
        let store = try SQLiteStateStore(url: url)
        let folder = RemoteItem(name: "folder", uri: "/folder", kind: .folder, contentType: "public.folder", version: ItemVersion(content: Data("f1".utf8), metadata: Data("m1".utf8)), canRead: true, canWrite: true, canAddChildren: true, canTrash: true)
        let child = RemoteItem(parentIdentifier: folder.itemIdentifier, name: "child", uri: "/folder/child", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true, canWrite: true)
        let backend = MemoryFileProviderBackend(items: [folder, child], contents: [child.itemIdentifier: Data("old".utf8)])
        try store.insertItem(folder); try store.insertItem(child)
        let fresh = try backend.modify(item: child, expectedVersion: child.version.content, changedFields: [.contents], content: Data("remote".utf8), replayKey: "remote")
        XCTAssertNotEqual(fresh.version.content, child.version.content)
        let coordinator = FileProviderMutationCoordinator(store: store, backend: backend)
        XCTAssertThrowsError(try coordinator.modify(item: child, baseVersion: NSFileProviderItemVersion(contentVersion: child.version.content, metadataVersion: child.version.metadata), fields: [.contents], contents: Data("local".utf8), options: [])) { error in
            XCTAssertEqual((error as? CoreFailure)?.code, .versionConflict)
        }
        XCTAssertThrowsError(try coordinator.delete(itemIdentifier: folder.itemIdentifier, baseVersion: NSFileProviderItemVersion(contentVersion: folder.version.content, metadataVersion: folder.version.metadata), options: [])) { error in
            XCTAssertEqual((error as? CoreFailure)?.code, .directoryNotEmpty)
        }
    }

    func testTrashRestoreRetainsOriginalParent() throws {
        let folder = RemoteItem(name: "folder", uri: "/folder", kind: .folder, contentType: "public.folder", version: ItemVersion(content: Data("f1".utf8), metadata: Data("m1".utf8)), canRead: true, canWrite: true, canTrash: true)
        let child = RemoteItem(parentIdentifier: folder.itemIdentifier, name: "child", uri: "/folder/child", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true, canWrite: true, canTrash: true)
        let backend = MemoryFileProviderBackend(items: [folder, child])
        let trashed = try backend.trash(item: child, expectedVersion: child.version.content, replayKey: "trash")
        XCTAssertEqual(trashed.parentIdentifier, NSFileProviderItemIdentifier.trashContainer.rawValue)
        XCTAssertEqual(trashed.trashOriginalParentIdentifier, folder.itemIdentifier)
        let restored = try backend.restore(item: trashed, expectedVersion: trashed.version.content, replayKey: "restore")
        XCTAssertEqual(restored.parentIdentifier, folder.itemIdentifier)
        XCTAssertNil(restored.trashOriginalParentIdentifier)
    }

    func testMemoryBackendRecursiveDeleteRemovesNestedDescendants() throws {
        let folder = RemoteItem(name: "folder", uri: "/folder", kind: .folder, contentType: "public.folder", version: ItemVersion(content: Data("f".utf8), metadata: Data("m".utf8)), canRead: true, canWrite: true, canAddChildren: true)
        let child = RemoteItem(parentIdentifier: folder.itemIdentifier, name: "child", uri: "/folder/child", kind: .folder, contentType: "public.folder", version: ItemVersion(content: Data("c".utf8), metadata: Data("m".utf8)), canRead: true, canWrite: true, canAddChildren: true)
        let grandchild = RemoteItem(parentIdentifier: child.itemIdentifier, name: "grandchild", uri: "/folder/child/grandchild", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("g".utf8), metadata: Data("m".utf8)), canRead: true, canWrite: true)
        let backend = MemoryFileProviderBackend(items: [folder, child, grandchild])
        try backend.delete(identifier: folder.itemIdentifier, expectedVersion: folder.version.content, recursive: true)
        XCTAssertNil(try backend.item(identifier: folder.itemIdentifier))
        XCTAssertNil(try backend.item(identifier: child.itemIdentifier))
        XCTAssertNil(try backend.item(identifier: grandchild.itemIdentifier))
    }

    func testEventScopeGuardRejectsRootAndOutOfScopeHints() {
        var guarder = EventScopeGuard(rootRemoteID: "root", rootURI: "/team")
        XCTAssertFalse(guarder.accepts(remoteID: "root", fromURI: "/team", toURI: nil))
        XCTAssertFalse(guarder.accepts(remoteID: "child", fromURI: "/other/file", toURI: nil))
        XCTAssertTrue(guarder.accepts(remoteID: "child", fromURI: "/team/file", toURI: "/team/new"))
        XCTAssertEqual(guarder.rejectedCount, 2)
    }

    func testEventScopeGuardAcceptsCloudreveCreateWithEmptyDestination() {
        var guarder = EventScopeGuard(rootRemoteID: "root", rootURI: "/team")
        XCTAssertTrue(guarder.accepts(remoteID: "child", fromURI: "/team/new-file.dmg", toURI: ""))
        XCTAssertEqual(guarder.rejectedCount, 0)
    }

    func testCloudreveCreateWithEmptyDestinationCommitsItemAndSignalOutbox() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-remote-create-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let parent = NSFileProviderItemIdentifier.rootContainer.rawValue
        let item = RemoteItem(itemIdentifier: CloudreveIdentifier.item(), remoteID: "remote-new", parentIdentifier: parent, name: "new-file.dmg", uri: "/team/new-file.dmg", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true)
        let change = EnrichedRemoteChange(item: item, oldParentIdentifier: nil, newParentIdentifier: parent, kind: "created")
        let pipeline = EventNormalizationPipeline(scopeGuard: EventScopeGuard(rootRemoteID: "root", rootURI: "/team"), enricher: FixedRemoteEventEnricher(change: change), writer: EventJournalWriter(store: store))

        let result = await pipeline.consume(RemoteEventHint(kind: .file, remoteID: "remote-new", fromURI: "/team/new-file.dmg", toURI: ""))

        XCTAssertEqual(result, .applied, "a live change with no echo evidence is applied, not skipped")
        XCTAssertEqual(try store.item(identifier: item.itemIdentifier), item)
        XCTAssertEqual(try store.pendingOutboxCount(), 1)
        let pendingScopes = await pipeline.scopesNeedingReconciliation()
        XCTAssertTrue(pendingScopes.isEmpty)
    }

    /// Only a change that really could not be applied is reported as skipped; the app logs each
    /// skip as a warning, so an applied change must never look like one.
    func testPipelineOutcomesSeparateAppliedRepeatedOutOfScopeAndMissing() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-remote-outcomes-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let parent = NSFileProviderItemIdentifier.rootContainer.rawValue
        let item = RemoteItem(itemIdentifier: CloudreveIdentifier.item(), remoteID: "remote-a", parentIdentifier: parent, name: "a.txt", uri: "/team/a.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true)
        let change = EnrichedRemoteChange(item: item, oldParentIdentifier: nil, newParentIdentifier: parent, kind: "modify")
        let pipeline = EventNormalizationPipeline(scopeGuard: EventScopeGuard(rootRemoteID: "root", rootURI: "/team"), enricher: FixedRemoteEventEnricher(change: change), writer: EventJournalWriter(store: store))

        let hint = RemoteEventHint(kind: .file, remoteID: "remote-a", fromURI: "/team/a.txt", toURI: "")
        let first = await pipeline.consume(hint)
        XCTAssertEqual(first, .applied)
        let repeated = await pipeline.consume(hint)
        XCTAssertEqual(repeated, .unchanged, "the same version twice writes once")
        let root = await pipeline.consume(RemoteEventHint(kind: .file, remoteID: "root"))
        XCTAssertEqual(root, .outsideScope)
        let elsewhere = await pipeline.consume(RemoteEventHint(kind: .file, remoteID: "remote-b", fromURI: "/other/b.txt"))
        XCTAssertEqual(elsewhere, .outsideScope)

        let missing = EventNormalizationPipeline(scopeGuard: EventScopeGuard(rootRemoteID: "root", rootURI: "/team"), enricher: MissingRemoteEventEnricher(), writer: EventJournalWriter(store: store))
        let gone = await missing.consume(RemoteEventHint(kind: .file, remoteID: "remote-gone", fromURI: "/team/gone.txt"))
        XCTAssertEqual(gone, .skipped(reason: "not_found"))
        let pendingScopes = await missing.scopesNeedingReconciliation()
        XCTAssertEqual(pendingScopes, ["/team/gone.txt"])
    }

    func testEchoMatcherRequiresParentNameTrashAndVersionEvidence() {
        let item = RemoteItem(itemIdentifier: "cri-item", remoteID: "remote", parentIdentifier: "cri-parent", name: "file.txt", uri: "/file.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true, trashed: false)
        let evidence = EchoEvidence(remoteID: "remote", operationID: UUID(), expectedParentIdentifier: "cri-parent", expectedName: "file.txt", expectedTrashed: false, expectedVersion: Data("v1".utf8))
        XCTAssertEqual(EchoMatcher.match(evidence, item: item), .matched)
        var moved = item; moved.parentIdentifier = "cri-other"
        XCTAssertEqual(EchoMatcher.match(evidence, item: moved), .realDifference)
    }

    func testGenerationReconciliationCannotCommitBeforeCompleteScan() throws {
        var run = ReconcileGeneration(generation: 2, capabilityRevision: 7, rootRemoteID: "root", startSequence: 4)
        run.startNormal(); run.finishNormal()
        XCTAssertThrowsError(try run.stabilize())
        run.startTrash(); run.finishTrash(); try run.stabilize()
        XCTAssertThrowsError(try run.beginDeletionCommit(currentCapabilityRevision: 8, currentRootRemoteID: "root"))
        XCTAssertEqual(run.phase, .failed)
    }

    func testFairSchedulerUsesBoundedRoundRobinSlots() async {
        let scheduler = FairDomainScheduler(limit: 2)
        await scheduler.enqueue("a"); await scheduler.enqueue("b"); await scheduler.enqueue("c")
        let first = await scheduler.next()
        let second = await scheduler.next()
        let third = await scheduler.next()
        XCTAssertEqual(first, "a")
        XCTAssertEqual(second, "b")
        XCTAssertNil(third)
        await scheduler.finish("a")
        let fourth = await scheduler.next()
        XCTAssertEqual(fourth, "c")
    }

    func testHealthProjectionDoesNotBecomeHealthyWhenAppQuits() {
        var projection = DomainConsistencyProjection()
        projection.inputs.authenticated = true; projection.inputs.rootAvailable = true; projection.inputs.scopeValid = true; projection.inputs.validAnchor = true; projection.inputs.recentlyReconciled = true; projection.inputs.appRunning = true
        XCTAssertEqual(projection.status(), .healthy)
        projection.setAppRunning(false)
        XCTAssertEqual(projection.status(), .appNotRunning)
    }

    func testReconcileSafetyDoesNotCreateTombstonesBeforeBothTreesComplete() {
        let safety = ReconcileSafety()
        let incomplete = ReconcileItemSet(expectedRemoteIDs: ["a", "b"], normalRemoteIDs: ["a"], trashRemoteIDs: [], pendingRemoteIDs: [], normalComplete: true, trashComplete: false)
        XCTAssertTrue(safety.tombstoneCandidates(incomplete).isEmpty)
        let complete = ReconcileItemSet(expectedRemoteIDs: ["a", "b"], normalRemoteIDs: ["a"], trashRemoteIDs: [], pendingRemoteIDs: [], normalComplete: true, trashComplete: true)
        XCTAssertEqual(safety.tombstoneCandidates(complete), ["b"])
    }

    func testReconcileSchedulerTriggersOnGapAndIntervals() {
        let scheduler = ReconcileScheduler(workingInterval: 60, fullInterval: 120)
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(scheduler.shouldReconcile(lastWorking: now.addingTimeInterval(-10), lastFull: now.addingTimeInterval(-10), now: now, reason: "anchor_expired"))
        XCTAssertFalse(scheduler.shouldReconcile(lastWorking: now.addingTimeInterval(-10), lastFull: now.addingTimeInterval(-10), now: now))
        XCTAssertTrue(scheduler.shouldReconcile(lastWorking: now.addingTimeInterval(-61), lastFull: now.addingTimeInterval(-10), now: now))
    }

    func testProductProjectionsAndReleaseFenceFailClosed() throws {
        var tasks = TaskProjection()
        let task = ProductTask(domainIdentifier: CloudreveIdentifier.domain(), title: "file.txt", direction: .upload, state: .failed)
        tasks.upsert(task); tasks.retry(task.id)
        XCTAssertEqual(tasks.active().first?.state, .retrying)
        XCTAssertTrue(UpgradeFence.canWrite(schemaVersion: 1, compatibilityMinimum: 1, compatibilityMaximum: 2, processGeneration: 3, currentGeneration: 3))
        XCTAssertFalse(UpgradeFence.canWrite(schemaVersion: 3, compatibilityMinimum: 1, compatibilityMaximum: 2, processGeneration: 3, currentGeneration: 3))
        let manifest = ReleaseManifest(version: "1.0.0", commit: "abc", swiftVersion: "6.2", architectures: ["arm64"], artifacts: [:], supportMatrix: [SupportMatrixEntry(component: "S3", version: "v4", architecture: "arm64", status: .unverified, evidence: "none")], gates: ["build": true])
        XCTAssertFalse(manifest.isReleaseCandidate)
    }

    func testExclusionRuleValidationAndDeepLinksAreOpaque() async throws {
        let store = try SQLiteStateStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-rules-\(UUID().uuidString).sqlite3"))
        let service = ExclusionRuleService(store: store)
        let rules = try await service.compile(revision: 1, text: "*.tmp\n# comment\nbuild/**")
        XCTAssertTrue(rules.matches(relativePath: "build/output.o"))
        XCTAssertTrue(rules.matches(relativePath: "notes.tmp"))
        XCTAssertFalse(rules.matches(relativePath: "folder/notes.txt"))
        let remoteItem = RemoteItem(name: "output.o", uri: "/team/build/output.o", kind: .file, contentType: "public.data", version: ItemVersion(content: Data(), metadata: Data()))
        let impact = await service.preview(rules, items: [remoteItem], rootURI: "/team")
        XCTAssertEqual(impact.remoteMatches, 1)
        XCTAssertNil(DeepLinkRouter.destination(url: URL(string: "nimbussync://conflict/not-an-id")!))
        let conflictID = UUID()
        XCTAssertEqual(DeepLinkRouter.destination(url: URL(string: "nimbussync://conflict/\(conflictID.uuidString)")!), .conflict(conflictID))
        let itemID = CloudreveIdentifier.item()
        XCTAssertEqual(DeepLinkRouter.destination(url: URL(string: "nimbussync://item/\(itemID)")!), .item(itemID))
        XCTAssertEqual(DeepLinkRouter.destination(url: URL(string: "nimbussync://settings")!), .settings)
        XCTAssertNil(DeepLinkRouter.destination(url: URL(string: "cloudreve-macos://settings")!))
    }

    func testProvisioningRecoveryAndRemovalDefaultToFailClosed() {
        let record = DomainProvisioningRecord(domainID: CloudreveIdentifier.domain(), step: .systemDomainAdded)
        XCTAssertEqual(DomainProvisioningReducer.recover(record: record, systemDomainExists: false), .rollbackRequired)
        XCTAssertEqual(DomainProvisioningReducer.recover(record: record, systemDomainExists: true), .systemDomainAdded)
        let registered = DomainProvisioningRecord(domainID: CloudreveIdentifier.domain(), step: .registered)
        XCTAssertEqual(DomainProvisioningReducer.recover(record: registered, systemDomainExists: false), .rollbackRequired)
        XCTAssertEqual(DomainRemovalPolicy().decision(hasDirtyOperations: false, pendingSetReliable: false, waitForChangesSucceeded: true), .preserveDirtyData)
        XCTAssertEqual(DomainRemovalPolicy().decision(hasDirtyOperations: true, pendingSetReliable: true, waitForChangesSucceeded: true), .preserveDirtyData)
    }

    func testOrphanedSystemDomainsAreIdentifiedForStartupCleanup() {
        let registryID = CloudreveIdentifier.domain()
        let legacyOrphan = "nimbussync-legacy-" + UUID().uuidString.lowercased()
        let systemDomains = [
            RegisteredDomainSnapshot(identifier: registryID, displayName: "Cloudreve"),
            RegisteredDomainSnapshot(identifier: legacyOrphan, displayName: "NimbusSync Legacy"),
        ]
        XCTAssertEqual(OrphanedDomainCleanupReducer.orphanedIdentifiers(systemDomains: systemDomains, registryIdentifiers: [registryID]), [legacyOrphan])
        XCTAssertEqual(OrphanedDomainCleanupReducer.orphanedIdentifiers(systemDomains: systemDomains, registryIdentifiers: [registryID, legacyOrphan]), [])
        // An empty registry (reset/recreated database) must never remove
        // every registered location.
        XCTAssertEqual(OrphanedDomainCleanupReducer.orphanedIdentifiers(systemDomains: systemDomains, registryIdentifiers: []), [])
        XCTAssertEqual(OrphanedDomainCleanupReducer.orphanedIdentifiers(systemDomains: [], registryIdentifiers: [registryID]), [])
    }

    func testProvisioningErrorsAreLocalizedAndFileProviderDiagnosticsAreRetained() {
        let providerDescription = ErrorDescription("provider unavailable", domain: "NSFileProviderErrorDomain", code: -2001)
        XCTAssertEqual(providerDescription.diagnosticDescription, "file_provider_error:NSFileProviderErrorDomain:-2001")
        XCTAssertTrue(providerDescription.userMessage.contains("File Provider extension is unavailable"))

        let lifecycleError = DomainLifecycleError.system(providerDescription)
        XCTAssertEqual(lifecycleError.diagnosticDescription, providerDescription.diagnosticDescription)
        XCTAssertEqual(lifecycleError.errorDescription, providerDescription.userMessage)

        let provisioningError = DomainProvisioningError.rollbackRequired(providerDescription.diagnosticDescription)
        XCTAssertTrue((provisioningError as LocalizedError).errorDescription?.contains("could not add") == true)
        XCTAssertFalse((provisioningError as LocalizedError).errorDescription?.contains("rollbackRequired") == true)
        XCTAssertEqual(provisioningError.diagnosticDescription, providerDescription.diagnosticDescription)

        let nameConflict = DomainProvisioningError.displayNameUnavailable
        XCTAssertTrue((nameConflict as LocalizedError).errorDescription?.contains("different name") == true)
        XCTAssertEqual(nameConflict.diagnosticDescription, "display_name_unavailable")

        let fileExists = ErrorDescription("file exists", domain: "NSCocoaErrorDomain", code: 516)
        XCTAssertTrue(fileExists.userMessage.contains("still registered"))
    }

    func testSecretRedactionDoesNotPersistCredentialMaterial() {
        let value = "Authorization: Bearer abc123 refresh_token=def456 https://example.com/file?token=ghi789"
        let redacted = SecretRedactor.redact(value)
        XCTAssertFalse(redacted.contains("abc123"))
        XCTAssertFalse(redacted.contains("def456"))
        XCTAssertFalse(redacted.contains("ghi789"))
        XCTAssertTrue(redacted.contains("REDACTED"))
        XCTAssertFalse(SecretRedactor.redact("https://storage.example/file?X-Amz-Signature=leaked&x-goog-credential=also-leaked").contains("leaked"))
    }

    func testExclusionIntentMustMatchEveryReplayDimension() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-exclusion-\(UUID().uuidString).sqlite3")
        defer { if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) } }
        let store = try SQLiteStateStore(url: url)
        let intent = ExclusionIntent(itemIdentifier: "cri-item", systemItemIdentifier: "system-item", ruleRevision: 4, kind: .unsupportedLocalType, sourceGeneration: 9)
        try store.createExclusionIntent(intent)
        XCTAssertFalse(try store.consumeMatchingExclusionIntent(itemIdentifier: "cri-item", systemItemIdentifier: "system-item", kind: .unsupportedLocalType, ruleRevision: 3, sourceGeneration: 9))
        XCTAssertTrue(try store.consumeMatchingExclusionIntent(itemIdentifier: "cri-item", systemItemIdentifier: "system-item", kind: .unsupportedLocalType, ruleRevision: 4, sourceGeneration: 9))
        XCTAssertFalse(try store.consumeMatchingExclusionIntent(itemIdentifier: "cri-item", systemItemIdentifier: "system-item", kind: .unsupportedLocalType, ruleRevision: 4, sourceGeneration: 9))
    }

    func testCapabilityWriteRequiresVerifiedRecoveryAndZeroByteSupport() throws {
        let provider = CapabilitySnapshot.Provider(name: "s3", read: .verified, write: .verified, resumable: .unverified, zeroByte: .verified, crypto: .verified)
        let writeOperations = CapabilitySnapshot.OperationCapabilities(collisionSafeCreate: .verified, conditionalModify: .verified, resumable: .verified)
        let snapshot = CapabilitySnapshot(revision: 1, stableItemIdentity: .verified, stableRootIdentity: .verified, conditionalContentWrite: .verified, idempotentCreate: .verified, contentVersionSemantics: .verified, resumableUploadProviders: ["s3"], uploadCompletionQueryableProviders: ["s3"], resolvedUploadPolicyKinds: ["s3"], providers: [provider], operations: writeOperations)
        XCTAssertFalse(snapshot.canWrite(provider: "s3"))
        let complete = CapabilitySnapshot.Provider(name: "s3", read: .verified, write: .verified, resumable: .verified, zeroByte: .verified, crypto: .verified)
        let verified = CapabilitySnapshot(revision: 2, stableItemIdentity: .verified, stableRootIdentity: .verified, conditionalContentWrite: .verified, idempotentCreate: .verified, contentVersionSemantics: .verified, resumableUploadProviders: ["s3"], uploadCompletionQueryableProviders: ["s3"], resolvedUploadPolicyKinds: ["s3"], providers: [complete], operations: writeOperations)
        XCTAssertTrue(verified.canWrite(provider: "s3"))
        XCTAssertTrue(verified.canWrite(provider: "S3"))
        XCTAssertFalse(verified.canWriteZeroByte(provider: "s3"))
        var operations = CapabilitySnapshot.OperationCapabilities(collisionSafeCreate: .verified, conditionalModify: .verified, zeroByte: .verified)
        operations.resumable = .verified
        let zeroByteVerified = CapabilitySnapshot(revision: 3, stableItemIdentity: .verified, stableRootIdentity: .verified, conditionalContentWrite: .verified, idempotentCreate: .verified, contentVersionSemantics: .verified, resumableUploadProviders: ["s3"], uploadCompletionQueryableProviders: ["s3"], zeroByteWriteProviders: ["s3"], resolvedUploadPolicyKinds: ["s3"], providers: [complete], operations: operations)
        XCTAssertTrue(zeroByteVerified.canWriteZeroByte(provider: "s3"))

        let encoded = try JSONEncoder().encode(zeroByteVerified)
        let roundTrip = try JSONDecoder().decode(CapabilitySnapshot.self, from: encoded)
        XCTAssertEqual(roundTrip, zeroByteVerified)

        let legacy = try JSONDecoder().decode(CapabilitySnapshot.self, from: Data(#"{"revision":1,"stableItemIdentity":"verified","stableRootIdentity":"verified","conditionalContentWrite":"verified","idempotentCreate":"verified","trashRestore":"unsupported","sse":"unverified","providers":[]}"#.utf8))
        XCTAssertEqual(legacy.contentVersionSemantics, .unverified)
        XCTAssertEqual(legacy.completePagination, .unverified)
        XCTAssertTrue(legacy.resumableUploadProviders.isEmpty)
        XCTAssertEqual(legacy.sseResume, legacy.sse)
        XCTAssertFalse(legacy.allowsWrite)
    }

    func testProvisioningAndReconcileRecordsHaveRuntimeColumns() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-schema-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let domainID = CloudreveIdentifier.domain()
        try store.beginProvisioning(domainID: domainID)
        try store.advanceProvisioning(domainID: domainID, step: .credentialWritten)
        XCTAssertEqual(try store.incompleteProvisioning().first?.step, .credentialWritten)
        let runID = UUID()
        try store.startReconcile(runID: runID, scope: "domain", generation: 1, phase: "prepared", cursor: nil)
        try store.updateReconcile(runID: runID, phase: "scanning_normal", cursor: "page:2", state: "active")
        XCTAssertEqual(try store.activeReconcileRuns().first?.id, runID)
        try store.updateReconcile(runID: runID, phase: "scanning_normal", cursor: "page:2", state: "failed")
        XCTAssertEqual(try store.activeReconcileRuns().first?.cursor, "page:2")
        XCTAssertEqual(try store.activeReconcileRuns().first?.state, "failed")
    }

    func testPreparingMigrationIsRecoveredBeforeWritesResume() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-migration-recovery-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let store = try SQLiteStateStore(url: url)
            try store.beginMigration(targetVersion: SQLiteStateStore.schemaVersion, compatibilityMinimum: SQLiteStateStore.schemaVersion, compatibilityMaximum: SQLiteStateStore.schemaVersion)
            XCTAssertEqual(try store.schemaFence().migrationState, "preparing")
        }
        let reopened = try SQLiteStateStore(url: url)
        let fence = try reopened.schemaFence()
        XCTAssertEqual(fence.migrationState, "ready")
        XCTAssertTrue(fence.permits(processGeneration: fence.generation, schemaVersion: SQLiteStateStore.schemaVersion))
    }

    func testRemoteChangePersistsItemJournalAndOutboxAtomically() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-atomic-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        let descriptor = DomainDescriptor(displayName: "Test", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential-ref")
        try store.registerDomain(descriptor)
        let item = RemoteItem(itemIdentifier: CloudreveIdentifier.item(), remoteID: "remote-atomic", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "atomic.txt", uri: "/atomic.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true)
        let change = try store.commitProviderChange(item: item, oldParentIdentifier: nil, newParentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, kind: "created", origin: "remote_event")
        XCTAssertEqual(try store.item(identifier: item.itemIdentifier), item)
        XCTAssertEqual(change.sequence, 1)
        XCTAssertEqual(try store.pendingOutboxCount(), 1)
    }

    func testRemoteMetadataDatesAndPermissionsSurviveStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-item-metadata-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let modified = Date(timeIntervalSince1970: 1_700_000_123)
        let item = RemoteItem(remoteID: "remote-metadata", name: "metadata.txt", uri: "/metadata.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v".utf8), metadata: Data("m".utf8)), creationDate: created, contentModificationDate: modified, canRead: true, canWrite: true)
        try store.insertItem(item)
        let restored = try XCTUnwrap(try store.item(identifier: item.itemIdentifier))
        XCTAssertEqual(try XCTUnwrap(restored.creationDate).timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(restored.contentModificationDate).timeIntervalSince1970, modified.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(restored.canRead)
        XCTAssertTrue(restored.canWrite)
    }

    func testConflictProjectionRetainsCreationDateAndPendingDecorationState() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-conflict-date-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_123)
        let conflict = ConflictProjection(conflictID: UUID(), itemIdentifier: "cri-item", kind: "version_conflict", baseSummary: "base", remoteSummary: "remote", localSummary: "local", pendingItemIdentifier: "cri-item", sourceGeneration: 2, createdAt: createdAt)
        try store.saveConflict(conflict)
        let restored = try XCTUnwrap(try store.pendingConflicts().first)
        XCTAssertEqual(restored.createdAt.timeIntervalSince1970, createdAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(try store.hasPendingConflict(itemIdentifier: "cri-item"))
    }

    func testUnavailableFileProviderBackendNeverServesDetachedMemoryState() {
        let backend = UnavailableFileProviderBackend()
        XCTAssertThrowsError(try backend.children(parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue)) { error in
            XCTAssertEqual((error as? CoreFailure)?.code, .database)
        }
    }

    func testCancelledMutationDoesNotReachBackend() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-cancel-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let template = RemoteItem(itemIdentifier: CloudreveIdentifier.item(forTemplate: "cancel-template"), parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "cancel.txt", uri: "/cancel.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data(), metadata: Data()), canRead: true, canWrite: true)
        let operationID = try XCTUnwrap(UUID(uuidString: String(template.itemIdentifier.dropFirst(4))))
        let backend = MemoryFileProviderBackend()
        let coordinator = FileProviderMutationCoordinator(store: store, backend: backend)
        _ = try store.upsertOperation(PendingOperation(operationID: operationID, replayKey: template.itemIdentifier, kind: "create", itemIdentifier: template.itemIdentifier))
        try store.requestCancel(operationID: operationID)
        XCTAssertThrowsError(try coordinator.create(template: template, content: Data("cancel".utf8), fields: [.contents], options: [])) { error in
            XCTAssertEqual((error as? CoreFailure)?.code, .cancelled)
        }
        XCTAssertEqual(try backend.children(parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue).count, 0)
    }

    func testCommittedMutationWithoutDurableOutcomeFailsClosed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-missing-outcome-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let template = RemoteItem(itemIdentifier: CloudreveIdentifier.item(forTemplate: "missing-outcome"), parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "outcome.txt", uri: "/outcome.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data(), metadata: Data()), canRead: true, canWrite: true)
        let operationID = try XCTUnwrap(UUID(uuidString: String(template.itemIdentifier.dropFirst(4))))
        _ = try store.upsertOperation(PendingOperation(operationID: operationID, replayKey: template.itemIdentifier, kind: "create", itemIdentifier: template.itemIdentifier))
        try store.commitOperation(operationID: operationID, state: "committed", itemIdentifier: template.itemIdentifier)
        let backend = MemoryFileProviderBackend()
        let coordinator = FileProviderMutationCoordinator(store: store, backend: backend)
        XCTAssertThrowsError(try coordinator.create(template: template, content: Data("outcome".utf8), fields: [.contents], options: [])) { error in
            XCTAssertEqual((error as? CoreFailure)?.code, .unknownOutcome)
        }
        XCTAssertEqual(try backend.children(parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue).count, 0)
    }

    func testTerminalConflictReplayDoesNotRetryRemoteDelete() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-terminal-conflict-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let item = RemoteItem(itemIdentifier: CloudreveIdentifier.item(), remoteID: "remote-terminal", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "terminal.txt", uri: "/terminal.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true, canWrite: true)
        try store.insertItem(item)
        let base = NSFileProviderItemVersion(contentVersion: item.version.content, metadataVersion: item.version.metadata)
        let replayKey = "delete|\(item.itemIdentifier)|\(base.contentVersion.base64EncodedString())|0"
        _ = try store.upsertOperation(PendingOperation(replayKey: replayKey, kind: "delete", itemIdentifier: item.itemIdentifier, state: "conflict"))
        let backend = MemoryFileProviderBackend(items: [item])

        XCTAssertThrowsError(try FileProviderMutationCoordinator(store: store, backend: backend).delete(itemIdentifier: item.itemIdentifier, baseVersion: base, options: [])) { error in
            XCTAssertEqual((error as? CoreFailure)?.code, .versionConflict)
        }
        XCTAssertNotNil(try backend.item(identifier: item.itemIdentifier))
    }

    func testConflictResolutionCommitsProviderChangeForOverwrite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-conflict-journal-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let domainID = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        var operations = CapabilitySnapshot.OperationCapabilities(fallbackConflict: .verified)
        operations.collisionSafeCreate = .verified
        operations.conditionalModify = .verified
        try store.registerDomain(DomainDescriptor(identifier: domainID, displayName: "Conflict", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential", capabilitySnapshot: CapabilitySnapshot(stableItemIdentity: .verified, stableRootIdentity: .verified, conditionalContentWrite: .verified, idempotentCreate: .verified, operations: operations)))
        let item = RemoteItem(itemIdentifier: CloudreveIdentifier.item(), remoteID: "remote-conflict-journal", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "conflict.txt", uri: "/conflict.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true, canWrite: true)
        try store.insertItem(item)
        let local = Data("local".utf8)
        let conflict = ConflictProjection(itemIdentifier: item.itemIdentifier, kind: "version_conflict", baseSummary: "base", remoteSummary: "remote", localSummary: "local", pendingItemIdentifier: item.itemIdentifier, sourceGeneration: 1, remoteVersion: item.version.content, localSourceKind: "user_export", expectedBaseVersion: item.version.content, expectedSourceHash: Data(SHA256.hash(data: local)), expectedSourceSize: Int64(local.count))
        try store.saveConflict(conflict)
        let backend = MemoryFileProviderBackend(items: [item])
        let service = ConflictResolutionService(store: store, backend: backend)
        let updated = try service.overwriteRemote(conflict: conflict, localContent: local)

        XCTAssertEqual(updated.itemIdentifier, item.itemIdentifier)
        let anchor = try store.currentAnchor(domainIdentifier: domainID, scope: NSFileProviderItemIdentifier.workingSet.rawValue)
        let state = try store.syncState()
        let replay = try store.enumerateChanges(
            domainIdentifier: domainID,
            scope: anchor.scope,
            from: SyncAnchor(domainIdentifier: anchor.domainIdentifier, scope: anchor.scope, epoch: state.epoch, sequence: 0)
        )
        XCTAssertTrue(replay.changes.contains { $0.kind == "conflict_overwrite" })
    }

    func testCloudreveEventPayloadAcceptsReferenceFileIDAndSSEFrameLimit() throws {
        let decoder = EventHintDecoder()
        let payload = try decoder.decode(RemoteEventHint(kind: .file, payload: "{\"type\":\"create\",\"file_id\":\"remote-1\",\"from\":\"/team/a\",\"to\":\"\"}"))
        XCTAssertEqual(payload.id, "remote-1")
        XCTAssertEqual(payload.from, "/team/a")
        let parser = SSEParser(maxFrameBytes: 20)
        XCTAssertThrowsError(try parser.append(Data("data: 123456789\ndata: 123456789\n".utf8)))
    }

    func testMissingPrimaryEntityKeepsContentVersionStableAndDisablesContentWrite() throws {
        let first = RemoteContentVersionPolicy.resolve(primaryEntity: nil, stableEntityID: "unversioned-remote")
        let second = RemoteContentVersionPolicy.resolve(primaryEntity: nil, stableEntityID: "unversioned-remote")
        XCTAssertFalse(first.reliable)
        XCTAssertEqual(first.value, "unversioned:unversioned-remote")
        XCTAssertEqual(first, second)
        let verified = RemoteContentVersionPolicy.resolve(primaryEntity: "entity-v1", stableEntityID: "unversioned-remote")
        XCTAssertTrue(verified.reliable)
        XCTAssertEqual(verified.value, "entity-v1")
    }

    func testV7JournalPayloadIsImmutableAcrossLiveRowUpdates() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-immutable-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let domainID = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: domainID, displayName: "Test", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential"))
        let identifier = CloudreveIdentifier.item()
        let first = RemoteItem(itemIdentifier: identifier, remoteID: "remote-immutable", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "first.txt", uri: "/first.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true)
        let change = try store.commitProviderChange(item: first, oldParentIdentifier: nil, newParentIdentifier: first.parentIdentifier, kind: "created", origin: "test")
        var current = first
        current.name = "second.txt"
        current.uri = "/second.txt"
        current.version = ItemVersion(content: Data("v2".utf8), metadata: Data("m2".utf8))
        try store.insertItem(current)
        let anchor = SyncAnchor(domainIdentifier: domainID, scope: NSFileProviderItemIdentifier.rootContainer.rawValue, epoch: change.epoch, sequence: 0)
        let batch = try store.enumerateChanges(domainIdentifier: domainID, scope: NSFileProviderItemIdentifier.rootContainer.rawValue, from: anchor)
        XCTAssertEqual(try JSONDecoder().decode(RemoteItem.self, from: try XCTUnwrap(batch.changes.first?.itemPayload)), first)
        XCTAssertEqual(try store.item(identifier: identifier), current)
    }

    func testAnchorCorruptionAndCompactionFailClosedAsExpired() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-anchor-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let domainID = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: domainID, displayName: "Test", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential"))
        let item = RemoteItem(remoteID: "remote-anchor", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "anchor.txt", uri: "/anchor.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v".utf8), metadata: Data("m".utf8)), canRead: true)
        let change = try store.commitProviderChange(item: item, oldParentIdentifier: nil, newParentIdentifier: item.parentIdentifier, kind: "created", origin: "test")
        var encoded = try SyncAnchor(domainIdentifier: domainID, scope: NSFileProviderItemIdentifier.rootContainer.rawValue, epoch: change.epoch, sequence: 0).encoded()
        encoded[encoded.index(encoded.startIndex, offsetBy: max(0, encoded.count - 1))] ^= 1
        XCTAssertThrowsError(try SyncAnchor.decode(encoded))
        let expired = SyncAnchor(domainIdentifier: domainID, scope: NSFileProviderItemIdentifier.rootContainer.rawValue, epoch: UUID(), sequence: 0)
        XCTAssertThrowsError(try store.enumerateChanges(domainIdentifier: domainID, scope: NSFileProviderItemIdentifier.rootContainer.rawValue, from: expired)) { error in
            XCTAssertEqual(error as? StoreBridgeError, .anchorExpired)
        }
    }

    func testDirectorySnapshotPublishesOnlyAfterCompleteGeneration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-snapshot-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let domainID = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: domainID, displayName: "Test", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential"))
        let parent = NSFileProviderItemIdentifier.rootContainer.rawValue
        let item = RemoteItem(remoteID: "remote-snapshot", parentIdentifier: parent, name: "snapshot.txt", uri: "/snapshot.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v".utf8), metadata: Data("m".utf8)), canRead: true)
        let snapshot = try store.beginDirectorySnapshot(domainIdentifier: domainID, parentIdentifier: parent, ttl: 600)
        try store.appendDirectorySnapshotItems(snapshotID: snapshot.snapshotID, items: [item])
        XCTAssertThrowsError(try store.directorySnapshotPage(domainIdentifier: domainID, parentIdentifier: parent, generation: snapshot.generation, snapshotID: snapshot.snapshotID, offset: 0, limit: 10))
        try store.publishDirectorySnapshot(snapshotID: snapshot.snapshotID)
        let page = try store.directorySnapshotPage(domainIdentifier: domainID, parentIdentifier: parent, generation: snapshot.generation, snapshotID: snapshot.snapshotID, offset: 0, limit: 10)
        XCTAssertEqual(page.items, [item])
        XCTAssertTrue(page.complete)

        let rules = ExclusionRuleSnapshot(revision: 1, rules: ["*.tmp"])
        try store.setPreference(key: "exclusion.rules.\(domainID)", value: String(data: try JSONEncoder().encode(rules), encoding: .utf8)!)
        XCTAssertNil(try store.currentCompleteDirectorySnapshot(domainIdentifier: domainID, parentIdentifier: parent))
    }

    /// A Finder enumeration resolves a page's identities before its network round trip; when the
    /// app's full check records the same remote entity meanwhile, the page adopts that identity
    /// instead of failing on the one-live-row-per-remote-entity index.
    func testDirectorySnapshotAdoptsIdentityRecordedMeanwhile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-snapshot-race-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let domainID = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: domainID, displayName: "Test", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential"))
        let parent = NSFileProviderItemIdentifier.rootContainer.rawValue
        let listed = RemoteItem(remoteID: "remote-race", parentIdentifier: parent, name: "race.txt", uri: "/race.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v".utf8), metadata: Data("m".utf8)), canRead: true)
        let snapshot = try store.beginDirectorySnapshot(domainIdentifier: domainID, parentIdentifier: parent, ttl: 600)

        // The full check records the entity under its own identifier first.
        let recorded = listed.reidentified(as: CloudreveIdentifier.item())
        _ = try store.commitProviderChange(item: recorded, oldParentIdentifier: nil, newParentIdentifier: parent, kind: "reconciled", origin: "reconciliation")
        XCTAssertNotEqual(recorded.itemIdentifier, listed.itemIdentifier)

        try store.appendDirectorySnapshotItems(snapshotID: snapshot.snapshotID, items: [listed])
        try store.publishDirectorySnapshot(snapshotID: snapshot.snapshotID)
        let page = try store.directorySnapshotPage(domainIdentifier: domainID, parentIdentifier: parent, generation: snapshot.generation, snapshotID: snapshot.snapshotID, offset: 0, limit: 10)
        XCTAssertEqual(page.items.map(\.itemIdentifier), [recorded.itemIdentifier])
        XCTAssertEqual(try store.itemIdentifier(forRemoteID: "remote-race"), recorded.itemIdentifier)
        XCTAssertNil(try store.item(identifier: listed.itemIdentifier), "no second row for the same remote entity")
    }

    func testMaterializedPartialGenerationDoesNotClearPreviousFact() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-system-set-\(UUID().uuidString).sqlite3")
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-system-lock-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: lockURL)
        }
        let store = try SQLiteStateStore(url: url)
        let first = RemoteItem(remoteID: "remote-one", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "one", uri: "/one", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("1".utf8), metadata: Data("1".utf8)), canRead: true)
        let second = RemoteItem(remoteID: "remote-two", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "two", uri: "/two", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("2".utf8), metadata: Data("2".utf8)), canRead: true)
        try store.insertItem(first)
        try store.insertItem(second)
        let coordinator = SystemSetCoordinator(store: store, manager: nil, domainIdentifier: CloudreveIdentifier.domain(), lockDirectory: lockURL)
        try coordinator.applyMaterializedObservation(itemIdentifiers: [first.itemIdentifier, second.itemIdentifier], complete: true)
        XCTAssertTrue(try store.isMaterialized(first.itemIdentifier))
        XCTAssertTrue(try store.isMaterialized(second.itemIdentifier))
        try coordinator.applyMaterializedObservation(itemIdentifiers: [first.itemIdentifier], complete: false, nextPage: Data("next".utf8))
        XCTAssertTrue(try store.isMaterialized(first.itemIdentifier))
        XCTAssertTrue(try store.isMaterialized(second.itemIdentifier))
        XCTAssertEqual(try store.systemSetState(setKind: "materialized")?.refreshRequired, true)
        try coordinator.applyMaterializedObservation(itemIdentifiers: [second.itemIdentifier], complete: true)
        XCTAssertTrue(try store.isMaterialized(first.itemIdentifier))
        XCTAssertTrue(try store.isMaterialized(second.itemIdentifier))
        XCTAssertEqual(try store.systemSetState(setKind: "materialized")?.refreshRequired, false)
    }

    func testSystemSetClaimsFenceConcurrentOwners() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-system-fence-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let first = try XCTUnwrap(store.claimSystemSet(setKind: "materialized", ownerID: UUID()))
        XCTAssertNil(try store.claimSystemSet(setKind: "materialized", ownerID: UUID()))
        XCTAssertThrowsError(try store.setSystemSetCursor(claim: SystemSetClaim(setKind: "materialized", generation: first.generation, ownerID: UUID(), domainVersion: nil), cursor: Data("stale".utf8))) { error in
            XCTAssertEqual(error as? StoreBridgeError, .generationFenced)
        }
        try store.releaseSystemSetClaim(claim: first)
        XCTAssertNotNil(try store.claimSystemSet(setKind: "materialized", ownerID: UUID()))
    }

    func testProjectionPreservesMaterializationPinAndChildCountUnknown() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-projection-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let folder = RemoteItem(remoteID: "remote-folder", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "folder", uri: "/folder", kind: .folder, contentType: "public.folder", version: ItemVersion(content: Data("f".utf8), metadata: Data("fm".utf8)), canRead: true, canWrite: true)
        try store.insertItem(folder)
        try store.setMaterialized(folder.itemIdentifier, materialized: true)
        try store.setKeepDownloadedPolicy(identifier: folder.itemIdentifier, policy: .keepDownloaded)
        var refreshed = folder
        refreshed.name = "renamed"
        refreshed.version = ItemVersion(content: Data("f2".utf8), metadata: Data("fm2".utf8))
        try store.insertItem(refreshed)
        let projection = try XCTUnwrap(try store.itemProjection(identifier: folder.itemIdentifier))
        XCTAssertTrue(projection.localState.materialized)
        XCTAssertEqual(projection.localState.keepPolicy, .keepDownloaded)
        XCTAssertNil(projection.childItemCount)
        let item = NimbusSyncFileProviderItem(projection: projection)
        XCTAssertEqual(item.contentPolicy, .downloadEagerlyAndKeepDownloaded)
        XCTAssertFalse(item.userInfo?["canEvict"] as? Bool ?? true)
    }

    func testProjectionDoesNotMarkPendingUploadAsUploaded() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-pending-projection-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let item = RemoteItem(remoteID: "remote-pending", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "pending.txt", uri: "/pending.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v".utf8), metadata: Data("m".utf8)), canRead: true, canWrite: true)
        try store.insertItem(item)
        try store.setPending(item.itemIdentifier, templateIdentifier: nil, uploadError: "server_unreachable")
        let projection = try XCTUnwrap(try store.itemProjection(identifier: item.itemIdentifier))
        XCTAssertFalse(projection.isUploaded)
        XCTAssertTrue(projection.isPending)
        let providerItem = NimbusSyncFileProviderItem(projection: projection)
        XCTAssertFalse(providerItem.isUploaded)
        XCTAssertNotNil(providerItem.uploadingError)
    }

    func testJournalFoldOrdersParentsBeforeChildrenAndDeletesLast() {
        let parentID = CloudreveIdentifier.item()
        let childID = CloudreveIdentifier.item()
        let parent = RemoteItem(itemIdentifier: parentID, parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "parent", uri: "/parent", kind: .folder, contentType: "public.folder", version: ItemVersion(content: Data("p".utf8), metadata: Data("p".utf8)))
        let child = RemoteItem(itemIdentifier: childID, parentIdentifier: parentID, name: "child", uri: "/parent/child", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("c".utf8), metadata: Data("c".utf8)))
        var deletedParent = parent
        deletedParent.tombstone = true
        let folded = JournalChangeFold.fold([
            ProviderChangeInput(item: child, oldParentIdentifier: parentID, newParentIdentifier: parentID, kind: "modified", origin: "test"),
            ProviderChangeInput(item: deletedParent, oldParentIdentifier: parent.parentIdentifier, newParentIdentifier: nil, kind: "deleted", origin: "test")
        ])
        XCTAssertEqual(folded.map(\.item.itemIdentifier), [childID, parentID])
        XCTAssertEqual(folded.last?.kind, "deleted")
    }

    func testSourceFingerprintIsStreamingAndRejectsMismatchedConflictSource() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-source-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let content = Data(repeating: 7, count: 256 * 1024)
        try content.write(to: url, options: .atomic)
        let fingerprint = try FileProviderSourceFingerprint.digest(url: url)
        let source = ConflictLocalSource.userExport(sourceGeneration: 4, expectedHash: fingerprint.hash, expectedSize: fingerprint.size)
        XCTAssertTrue(try ConflictSourceValidator.validate(source, url: url, sourceGeneration: 4))
        XCTAssertFalse(try ConflictSourceValidator.validate(source, url: url, sourceGeneration: 5))
        XCTAssertFalse(ConflictSourceValidator.validateData(Data("wrong".utf8), source: source))
    }

    func testSwiftSchemaManifestIsV7AndHasNoDuplicateTables() {
        XCTAssertEqual(SQLiteSchemaManifest.version, 7)
        XCTAssertEqual(SQLiteSchemaManifest.tables.count, Set(SQLiteSchemaManifest.tables).count)
        XCTAssertTrue(SQLiteSchemaManifest.tables.contains("directory_snapshot_generations"))
        XCTAssertTrue(SQLiteSchemaManifest.tables.contains("system_pending_observations"))
        XCTAssertTrue(SQLiteSchemaManifest.tables.contains("projection_refresh_jobs"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-manifest-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try? SQLiteStateStore(url: url)
        if let store, let manifest = try? store.schemaManifest() {
            XCTAssertEqual(manifest.version, 7)
            XCTAssertEqual(Set(manifest.tables), Set(SQLiteSchemaManifest.tables))
            XCTAssertTrue(manifest.columns["change_journal"]?.contains("item_payload") == true)
            XCTAssertTrue(manifest.columns["system_set_state"]?.contains("active_generation") == true)
            // Golden schema snapshot: an intentional schema change must update
            // Tests/schema-manifest.json together with the migration.
            let workingTreeManifest = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("schema-manifest.json")
            let currentDirectoryManifest = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/schema-manifest.json")
            let sharedURL = FileManager.default.fileExists(atPath: workingTreeManifest.path) ? workingTreeManifest : currentDirectoryManifest
            if let sharedData = try? Data(contentsOf: sharedURL),
               let shared = try? JSONSerialization.jsonObject(with: sharedData) as? [String: Any],
               let sharedVersion = shared["version"] as? Int,
               let sharedTables = shared["tables"] as? [String],
               let sharedColumns = shared["columns"] as? [String: [String]],
               let sharedIndexes = shared["indexes"] as? [String] {
                XCTAssertEqual(sharedVersion, manifest.version)
                XCTAssertEqual(Set(sharedTables), Set(manifest.tables))
                XCTAssertEqual(manifest.columns, sharedColumns)
                XCTAssertEqual(manifest.indexes, sharedIndexes)
            } else {
                XCTFail("shared schema manifest unavailable")
            }
        } else {
            XCTFail("schema manifest unavailable")
        }
    }

    func testProjectionRefreshFailureRetainsResumableCursor() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-projection-refresh-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let domainID = CloudreveIdentifier.domain()
        let cursor = CloudreveIdentifier.item()
        let job = try store.beginProjectionRefresh(domainIdentifier: domainID, targetRevision: ProjectionSchema.currentRevision + 1)
        try store.advanceProjectionRefresh(jobID: job.jobID, cursor: cursor, state: "failed", error: "projection_refresh_failed")

        let resumed = try XCTUnwrap(store.activeProjectionRefreshJob(domainIdentifier: domainID))
        XCTAssertEqual(resumed.jobID, job.jobID)
        XCTAssertEqual(resumed.cursor, cursor)
        XCTAssertEqual(resumed.state, "failed")
        XCTAssertEqual(resumed.lastError, "projection_refresh_failed")
    }

    func testProjectionRefreshPageCommitsJournalAndCursorTogether() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-projection-refresh-page-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let domainID = CloudreveIdentifier.domain()
        let item = RemoteItem(remoteID: "projection-page", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "projection.txt", uri: "/projection.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true)
        try store.insertItem(item)
        let job = try store.beginProjectionRefresh(domainIdentifier: domainID)
        let before = try store.currentAnchor(domainIdentifier: domainID, scope: NSFileProviderItemIdentifier.workingSet.rawValue)
        try store.commitProjectionRefreshPage(jobID: job.jobID, items: [item], cursor: item.itemIdentifier)

        let resumed = try XCTUnwrap(store.activeProjectionRefreshJob(domainIdentifier: domainID))
        XCTAssertEqual(resumed.cursor, item.itemIdentifier)
        XCTAssertEqual(resumed.state, "active")
        XCTAssertEqual(try store.enumerateChanges(domainIdentifier: domainID, scope: NSFileProviderItemIdentifier.workingSet.rawValue, from: before).changes.count, 1)
    }

    func testProjectionRefreshDoesNotAdvanceAppliedRevisionBeforeSignalSucceeds() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-projection-signal-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let domainID = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: domainID, displayName: "Projection", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "ref"))
        let item = RemoteItem(remoteID: "projection-signal", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "signal.txt", uri: "/signal.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true)
        try store.insertItem(item)

        let failing = FrameworkCacheRefreshCoordinator(store: store, manager: nil, domainIdentifier: domainID, signalOverride: {
            throw CoreFailure(code: .network, retryable: true)
        })
        do {
            _ = try await failing.refreshIfNeeded()
            XCTFail("refresh must retain a retryable job when signalling fails")
        } catch {
            // Expected: the durable job remains failed and retryable.
        }
        let failedRevisions = try store.projectionRevisionState()
        XCTAssertLessThan(failedRevisions.lastApplied, failedRevisions.current)
        XCTAssertEqual(try store.pendingOutboxCount(), 1)
        let failedJobID = try XCTUnwrap(try store.activeProjectionRefreshJob(domainIdentifier: domainID)).jobID
        XCTAssertEqual(try store.projectionRefreshJob(jobID: failedJobID)?.state, "failed")

        let succeeding = FrameworkCacheRefreshCoordinator(store: store, manager: nil, domainIdentifier: domainID, signalOverride: {})
        let didComplete = try await succeeding.refreshIfNeeded()
        XCTAssertTrue(didComplete)
        let completedRevisions = try store.projectionRevisionState()
        XCTAssertEqual(completedRevisions.lastApplied, completedRevisions.current)
        XCTAssertEqual(try store.pendingOutboxCount(), 0)
        XCTAssertEqual(try store.projectionRefreshJob(jobID: failedJobID)?.state, "completed")
    }

    func testAwaitingSourceReplayRemainsActiveOperation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-source-replay-operation-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let itemIdentifier = CloudreveIdentifier.item()
        let expectedVersion = Data("base-version".utf8)
        let operation = PendingOperation(replayKey: "source-replay", kind: "modify", itemIdentifier: itemIdentifier, state: "awaiting_source_replay", expectedVersion: expectedVersion, changedFields: "contents")
        _ = try store.upsertOperation(operation)

        let active = try XCTUnwrap(store.activeOperation(itemIdentifier: itemIdentifier))
        XCTAssertEqual(active.operation.state, "awaiting_source_replay")
        XCTAssertEqual(active.operation.expectedVersion, expectedVersion)
        XCTAssertEqual(active.operation.changedFields, "contents")
        XCTAssertNil(active.outcome)
        XCTAssertTrue(try store.acquireOperationLease(operationID: operation.operationID, owner: UUID()))
    }

    func testCreateWithNewSourceSupersedesUnfinishedAttempt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-create-source-supersede-\(UUID().uuidString).sqlite3")
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-create-source-supersede-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: sourceURL)
        }
        let store = try SQLiteStateStore(url: url)
        let itemIdentifier = CloudreveIdentifier.item()
        let template = RemoteItem(itemIdentifier: itemIdentifier, parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "new.txt", uri: "/new.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data(), metadata: Data()), canRead: true, canWrite: true)
        let previous = PendingOperation(replayKey: "create|previous-source", kind: "create", itemIdentifier: itemIdentifier, state: "awaiting_source_replay")
        _ = try store.upsertOperation(previous)
        try Data("new-source".utf8).write(to: sourceURL, options: .atomic)
        let memory = MemoryFileProviderBackend()
        let backend = LegacyAsyncFileProviderBackendAdapter(backend: memory)
        let context = FileProviderOperationContext(itemIdentifier: NSFileProviderItemIdentifier(itemIdentifier), progress: Progress(totalUnitCount: 1), registrar: NoopURLSessionTaskRegistrar(), cancellation: CancellationToken())

        let created = try await AsyncFileProviderMutationCoordinator(store: store, backend: backend).create(template: template, contents: sourceURL, fields: [.contents], options: [], context: context)

        XCTAssertEqual(created.itemIdentifier, itemIdentifier)
        XCTAssertEqual(try memory.content(identifier: itemIdentifier, expectedVersion: nil), Data("new-source".utf8))
        XCTAssertEqual(try store.operation(replayKey: "create|previous-source")?.operation.state, "cancelled")
        XCTAssertNil(try store.activeOperation(itemIdentifier: itemIdentifier))
    }

    func testCommittedCreateIsNotRepeatedForADifferentSource() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-create-committed-\(UUID().uuidString).sqlite3")
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-create-committed-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: sourceURL)
        }
        let store = try SQLiteStateStore(url: url)
        let itemIdentifier = CloudreveIdentifier.item()
        let template = RemoteItem(itemIdentifier: itemIdentifier, parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "new.txt", uri: "/new.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data(), metadata: Data()), canRead: true, canWrite: true)
        let previous = PendingOperation(replayKey: "create|previous-source", kind: "create", itemIdentifier: itemIdentifier, state: "committed")
        _ = try store.upsertOperation(previous)
        try Data("new-source".utf8).write(to: sourceURL, options: .atomic)
        let backend = LegacyAsyncFileProviderBackendAdapter(backend: MemoryFileProviderBackend())
        let context = FileProviderOperationContext(itemIdentifier: NSFileProviderItemIdentifier(itemIdentifier), progress: Progress(totalUnitCount: 1), registrar: NoopURLSessionTaskRegistrar(), cancellation: CancellationToken())

        do {
            _ = try await AsyncFileProviderMutationCoordinator(store: store, backend: backend).create(template: template, contents: sourceURL, fields: [.contents], options: [], context: context)
            XCTFail("a committed create must not be repeated with a different source")
        } catch let failure as CoreFailure {
            XCTAssertEqual(failure.code, .unknownOutcome)
        }
    }

    func testTransferCompactionRetainsRecoverableSessionUntilCommit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-transfer-compaction-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let operation = PendingOperation(replayKey: "transfer-compaction", kind: "modify", itemIdentifier: CloudreveIdentifier.item())
        _ = try store.upsertOperation(operation)
        let session = UploadSessionCheckpoint(operationID: operation.operationID, remoteSessionReference: "remote-session", secretReference: "opaque-secret", fingerprint: Data("fingerprint".utf8), provider: "local", chunkSize: 4, expiresAt: Date().addingTimeInterval(600), state: "completed", parts: [UploadPartCheckpoint(index: 0, offset: 0, length: 4, sourceHash: Data("hash".utf8), state: "completed")])
        try store.saveUploadSession(session)
        try store.compactTransferState()
        XCTAssertNotNil(try store.uploadSession(operationID: operation.operationID))

        try store.commitOperation(operationID: operation.operationID, state: "committed", itemIdentifier: operation.itemIdentifier, outcome: "{}")
        XCTAssertNotNil(try store.uploadSession(operationID: operation.operationID))
        try store.clearUploadSessionSecretReference(operationID: operation.operationID)
        try store.compactTransferState()
        XCTAssertNil(try store.uploadSession(operationID: operation.operationID))
    }

    func testV6ToV7MigrationPreservesDirtyWorkAndCreatesFreshSignal() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-v6-migration-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let oldAnchor: SyncAnchor
        do {
            let store = try SQLiteStateStore(url: url)
            let domainID = CloudreveIdentifier.domain()
            let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
            try store.registerDomain(DomainDescriptor(identifier: domainID, displayName: "Migration", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential"))
            let item = RemoteItem(remoteID: "remote-migration", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "dirty.txt", uri: "/dirty.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true)
            let change = try store.commitProviderChange(item: item, oldParentIdentifier: nil, newParentIdentifier: item.parentIdentifier, kind: "created", origin: "test")
            oldAnchor = SyncAnchor(domainIdentifier: domainID, scope: NSFileProviderItemIdentifier.rootContainer.rawValue, epoch: change.epoch, sequence: 0)
            _ = try store.upsertOperation(PendingOperation(replayKey: "migration-dirty", kind: "modify", itemIdentifier: item.itemIdentifier))
        }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "UPDATE schema_meta SET version = 6, generation = 6, compat_min = 6, compat_max = 6, migration_state = 'ready' WHERE singleton = 1", nil, nil, nil), SQLITE_OK)
        if let handle { sqlite3_close(handle) }
        let migrated = try SQLiteStateStore(url: url)
        let fence = try migrated.schemaFence()
        XCTAssertEqual(fence.version, 7)
        XCTAssertEqual(fence.migrationState, "ready")
        XCTAssertEqual(try migrated.syncState().reconcileStatus, "required")
        XCTAssertEqual(try migrated.pendingOutboxCount(), 1)
        XCTAssertTrue(try migrated.hasDirtyWork())
        XCTAssertThrowsError(try migrated.enumerateChanges(domainIdentifier: oldAnchor.domainIdentifier, scope: oldAnchor.scope, from: oldAnchor)) { error in
            XCTAssertEqual(error as? StoreBridgeError, .anchorExpired)
        }
    }

    func testMigrationAddsTimestampColumnsToPopulatedLegacyTables() throws {
        // SQLite rejects ADD COLUMN with an expression default such as
        // (unixepoch()) once the table has rows; that used to fence the store
        // and made the Domain impossible to open or remove.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-legacy-timestamps-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try SQLiteStateStore(url: url)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let legacy = """
        DROP TABLE system_set_state;
        CREATE TABLE system_set_state (set_kind TEXT PRIMARY KEY, system_anchor BLOB, refresh_required INTEGER NOT NULL DEFAULT 0, refresh_cursor BLOB, last_completed_at INTEGER);
        INSERT INTO system_set_state (set_kind, refresh_required) VALUES ('pending', 1);
        DROP TABLE domain_actions;
        CREATE TABLE domain_actions (action_id TEXT PRIMARY KEY, domain_id TEXT NOT NULL, kind TEXT NOT NULL, step TEXT NOT NULL, state TEXT NOT NULL, error TEXT);
        INSERT INTO domain_actions (action_id, domain_id, kind, step, state) VALUES ('legacy-action', 'legacy-domain', 'provision', 'registered', 'completed');
        """
        XCTAssertEqual(sqlite3_exec(handle, legacy, nil, nil, nil), SQLITE_OK)
        if let handle { sqlite3_close(handle) }

        let migrated = try SQLiteStateStore(url: url)
        XCTAssertEqual(try migrated.schemaFence().migrationState, "ready")
        XCTAssertEqual(try migrated.pendingSetState().capped, false)
        XCTAssertEqual(Set(try migrated.schemaManifest().columns["system_set_state"] ?? []), Set(["set_kind", "system_anchor", "refresh_required", "refresh_cursor", "current_generation", "active_generation", "active_owner", "active_started_at", "scan_state", "maximum_size_reached", "domain_version", "last_completed_at", "updated_at"]))

        var readHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &readHandle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { if let readHandle { sqlite3_close(readHandle) } }
        for query in ["SELECT updated_at FROM system_set_state WHERE set_kind = 'pending'", "SELECT created_at FROM domain_actions WHERE action_id = 'legacy-action'"] {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(readHandle, query, -1, &statement, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertGreaterThan(sqlite3_column_int64(statement, 0), 0)
            sqlite3_finalize(statement)
        }
    }

    func testMigrationAddsUploadSessionItemColumnToPopulatedLegacyTable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-legacy-upload-sessions-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try SQLiteStateStore(url: url)
        let legacyOperationID = UUID()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let legacy = """
        DROP TABLE upload_sessions;
        CREATE TABLE upload_sessions (operation_id TEXT PRIMARY KEY, remote_session_ref TEXT, secret_ref TEXT, fingerprint BLOB NOT NULL, provider TEXT NOT NULL, chunk_size INTEGER NOT NULL, expires_at INTEGER, state TEXT NOT NULL, updated_at INTEGER NOT NULL DEFAULT (unixepoch()));
        INSERT INTO upload_sessions (operation_id, remote_session_ref, secret_ref, fingerprint, provider, chunk_size, expires_at, state) VALUES ('\(legacyOperationID.uuidString)', 'legacy-session', 'legacy-ref', X'01', 'remote', 4, NULL, 'active');
        """
        XCTAssertEqual(sqlite3_exec(handle, legacy, nil, nil, nil), SQLITE_OK)
        if let handle { sqlite3_close(handle) }

        let migrated = try SQLiteStateStore(url: url)
        XCTAssertEqual(try migrated.schemaFence().migrationState, "ready")
        XCTAssertEqual(try migrated.schemaManifest().columns["upload_sessions"], ["operation_id", "remote_session_ref", "secret_ref", "fingerprint", "provider", "chunk_size", "expires_at", "state", "updated_at", "item_uuid"])
        let legacySession = try XCTUnwrap(migrated.uploadSession(operationID: legacyOperationID))
        XCTAssertNil(legacySession.itemIdentifier)
        XCTAssertEqual(legacySession.remoteSessionReference, "legacy-session")
        XCTAssertEqual(legacySession.state, "active")

        let itemIdentifier = CloudreveIdentifier.item()
        let tracked = UploadSessionCheckpoint(operationID: UUID(), remoteSessionReference: "tracked-session", secretReference: nil, fingerprint: Data([2]), provider: "remote", chunkSize: 4, expiresAt: nil, state: "awaiting_source_replay", itemIdentifier: itemIdentifier)
        try migrated.saveUploadSession(tracked)
        XCTAssertEqual(try migrated.uploadSession(operationID: tracked.operationID)?.itemIdentifier, itemIdentifier)
        XCTAssertEqual(try migrated.supersededUploadSessions(itemIdentifier: itemIdentifier, currentOperationID: UUID()).map(\.operationID), [tracked.operationID])
        XCTAssertTrue(try migrated.supersededUploadSessions(itemIdentifier: itemIdentifier, currentOperationID: tracked.operationID).isEmpty)
    }

    func testV6ShapeMigrationKeepsItemColumnTypes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-v6-shape-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let oldSchema = """
        CREATE TABLE schema_meta (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), version INTEGER NOT NULL, generation INTEGER NOT NULL, compat_min INTEGER NOT NULL, compat_max INTEGER NOT NULL, migration_state TEXT NOT NULL);
        INSERT INTO schema_meta VALUES (1, 6, 6, 6, 6, 'ready');
        CREATE TABLE items (item_uuid TEXT PRIMARY KEY, remote_entity_id TEXT, parent_uuid TEXT, remote_name TEXT NOT NULL, kind TEXT NOT NULL, current_remote_uri TEXT NOT NULL, content_version BLOB NOT NULL, metadata_version BLOB NOT NULL, size INTEGER NOT NULL DEFAULT 0, remote_version TEXT, trashed INTEGER NOT NULL DEFAULT 0, tombstone INTEGER NOT NULL DEFAULT 0, created_at INTEGER, modified_at INTEGER, can_read INTEGER NOT NULL DEFAULT 0, can_write INTEGER NOT NULL DEFAULT 0, can_add_children INTEGER NOT NULL DEFAULT 0, can_trash INTEGER NOT NULL DEFAULT 0, can_delete INTEGER NOT NULL DEFAULT 0);
        INSERT INTO items (item_uuid, remote_entity_id, parent_uuid, remote_name, kind, current_remote_uri, content_version, metadata_version, can_read) VALUES ('cri-11111111-1111-4111-8111-111111111111', 'remote-v6', 'NSFileProviderRootContainerItemIdentifier', 'legacy.txt', 'file', '/legacy.txt', X'7631', X'6D31', 1);
        """
        XCTAssertEqual(sqlite3_exec(handle, oldSchema, nil, nil, nil), SQLITE_OK)
        if let handle { sqlite3_close(handle) }

        let migrated = try SQLiteStateStore(url: url)
        XCTAssertEqual(try migrated.schemaFence().version, 7)
        XCTAssertEqual(try migrated.item(identifier: "cri-11111111-1111-4111-8111-111111111111")?.name, "legacy.txt")

        var migratedHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &migratedHandle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { if let migratedHandle { sqlite3_close(migratedHandle) } }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(migratedHandle, "PRAGMA table_info(items)", -1, &statement, nil), SQLITE_OK)
        var types: [String: (type: String, notNull: Int32)] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawName = sqlite3_column_text(statement, 1), let rawType = sqlite3_column_text(statement, 2) else { continue }
            types[String(cString: rawName)] = (String(cString: rawType), sqlite3_column_int(statement, 3))
        }
        if let statement { sqlite3_finalize(statement) }
        XCTAssertEqual(types["trash_original_parent_uuid"]?.type, "TEXT")
        XCTAssertEqual(types["trash_original_parent_uuid"]?.notNull, 0)
        XCTAssertEqual(types["content_type"]?.type, "TEXT")
        XCTAssertEqual(types["content_type"]?.notNull, 1)
    }

    func testWorkingSetEnumeratorUsesOpaqueKeysetCursor() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-working-enumerator-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let domainID = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: domainID, displayName: "Test", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential"))
        for index in 0..<3 {
            let item = RemoteItem(remoteID: "remote-\(index)", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "item-\(index)", uri: "/item-\(index)", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("\(index)".utf8), metadata: Data("\(index)".utf8)), canRead: true)
            try store.insertItem(item)
            if index == 1 { try store.setMaterialized(item.itemIdentifier, materialized: true) }
        }
        XCTAssertEqual(try store.workingSetItems(limit: 10).count, 3)
        let observer = RecordingEnumerationObserver(suggestedPageSize: 2)
        let initialPage = NSFileProviderPage(Data(NSFileProviderPage.initialPageSortedByName as NSData))
        let enumerator = WorkingSetEnumerator(domainIdentifier: domainID, store: store, backend: MemoryFileProviderBackend())
        enumerator.enumerateItems(for: observer, startingAt: initialPage)
        await observer.wait()
        XCTAssertNil(observer.error)
        XCTAssertEqual(observer.items.count, 2)
        let nextPage = try XCTUnwrap(observer.nextPage)
        let token = try PageToken.decode(Data(nextPage as NSData))
        XCTAssertTrue(token.isWorkingSet)
        XCTAssertEqual(token.parentIdentifier, NSFileProviderItemIdentifier.workingSet.rawValue)
        let secondObserver = RecordingEnumerationObserver(suggestedPageSize: 2)
        let secondEnumerator = WorkingSetEnumerator(domainIdentifier: domainID, store: store, backend: MemoryFileProviderBackend())
        secondEnumerator.enumerateItems(for: secondObserver, startingAt: nextPage)
        await secondObserver.wait()
        XCTAssertNil(secondObserver.error)
        XCTAssertEqual(secondObserver.items.count, 1)
        XCTAssertNil(secondObserver.nextPage)
        XCTAssertTrue(Set(observer.items.map(\.itemIdentifier)).isDisjoint(with: Set(secondObserver.items.map(\.itemIdentifier))))
    }

    func testWorkingSetPageSurvivesConcurrentChangeWithoutSkipping() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-working-revision-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let domainID = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: domainID, displayName: "Test", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential"))
        for index in 0..<3 {
            let item = RemoteItem(remoteID: "remote-revision-\(index)", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "item-\(index)", uri: "/item-\(index)", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("\(index)".utf8), metadata: Data("\(index)".utf8)), canRead: true)
            try store.insertItem(item)
        }

        let firstObserver = RecordingEnumerationObserver(suggestedPageSize: 2)
        let initialPage = NSFileProviderPage(Data(NSFileProviderPage.initialPageSortedByName as NSData))
        WorkingSetEnumerator(domainIdentifier: domainID, store: store, backend: MemoryFileProviderBackend()).enumerateItems(for: firstObserver, startingAt: initialPage)
        await firstObserver.wait()
        let nextPage = try XCTUnwrap(firstObserver.nextPage)

        let newItem = RemoteItem(remoteID: "remote-revision-new", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "new.txt", uri: "/new.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("new".utf8), metadata: Data("new".utf8)), canRead: true)
        _ = try store.commitProviderChange(item: newItem, oldParentIdentifier: newItem.parentIdentifier, newParentIdentifier: newItem.parentIdentifier, kind: "created", origin: "test")

        // Keyset pagination is stable under concurrent writes; the change
        // itself is delivered by enumerateChanges. Rejecting the token on
        // every working-set revision bump livelocked large initial syncs.
        var seen = Set(firstObserver.items.map(\.itemIdentifier.rawValue))
        var page: NSFileProviderPage? = nextPage
        var pages = 0
        while let current = page, pages < 10 {
            pages += 1
            let observer = RecordingEnumerationObserver(suggestedPageSize: 2)
            WorkingSetEnumerator(domainIdentifier: domainID, store: store, backend: MemoryFileProviderBackend()).enumerateItems(for: observer, startingAt: current)
            await observer.wait()
            XCTAssertNil(observer.error)
            seen.formUnion(observer.items.map(\.itemIdentifier.rawValue))
            page = observer.nextPage
        }
        let originals = try (0..<3).map { index in try XCTUnwrap(store.itemIdentifier(forRemoteID: "remote-revision-\(index)")) }
        XCTAssertTrue(Set(originals).isSubset(of: seen), "no pre-existing item may be skipped")
    }

    func testURLSessionTaskRegistrationRequiresSuspendedTaskBeforeResume() async throws {
        URLProtocolProbe.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolProbe.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = RegisteredURLSessionTransport(session: session)
        let registrar = RecordingTaskRegistrar(shouldFail: false)
        let progress = Progress(totalUnitCount: 1)
        let token = CancellationToken()
        let context = FileProviderOperationContext(itemIdentifier: .rootContainer, progress: progress, registrar: registrar, cancellation: token)
        let request = URLRequest(url: URL(string: "https://unit.test/data")!)
        let result = try await transport.data(for: request, itemIdentifier: .rootContainer, context: context)
        XCTAssertEqual(result.0, Data("ok".utf8))
        let registrationStates = await registrar.states()
        let requestStarted = URLProtocolProbe.wasStarted()
        XCTAssertEqual(registrationStates, [.suspended])
        XCTAssertTrue(requestStarted)

        URLProtocolProbe.reset()
        let failingRegistrar = RecordingTaskRegistrar(shouldFail: true)
        let failureContext = FileProviderOperationContext(itemIdentifier: .rootContainer, progress: Progress(totalUnitCount: 1), registrar: failingRegistrar, cancellation: CancellationToken())
        do {
            _ = try await transport.data(for: request, itemIdentifier: .rootContainer, context: failureContext)
            XCTFail("registration failure must stop the attempt")
        } catch {
            let failureStates = await failingRegistrar.states()
            let failureStarted = URLProtocolProbe.wasStarted()
            XCTAssertEqual(failureStates, [.suspended])
            XCTAssertFalse(failureStarted)
        }
    }

    func testExclusionViewFilterIsAtomicAndNeverDeletesRemoteItem() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-exclusion-atomic-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let domainID = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: domainID, displayName: "Test", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential"))
        let item = RemoteItem(remoteID: "remote-filtered", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "build.tmp", uri: "/build.tmp", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v".utf8), metadata: Data("m".utf8)), canRead: true)
        try store.insertItem(item)
        let service = ExclusionApplicationService(store: store)
        let application = try await service.preview(revision: 4, text: "*.tmp", items: [item], rootURI: "/")
        try await service.apply(application, domainIdentifier: domainID, preserveDirty: true)
        XCTAssertTrue(try store.isExcludedByCurrentRules(item: item, domainIdentifier: domainID).excluded)
        XCTAssertTrue(try store.listChildren(parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue).isEmpty)
        XCTAssertEqual(try store.item(identifier: item.itemIdentifier), item)
        let removed = try store.enumerateChanges(domainIdentifier: domainID, scope: NSFileProviderItemIdentifier.rootContainer.rawValue, from: SyncAnchor(domainIdentifier: domainID, scope: NSFileProviderItemIdentifier.rootContainer.rawValue, epoch: try store.syncState().epoch, sequence: 0))
        XCTAssertEqual(removed.changes.last?.kind, "view_removed")

        let included = try await service.preview(revision: 5, text: "", items: [item], rootURI: "/")
        try await service.apply(included, domainIdentifier: domainID, preserveDirty: true)
        XCTAssertFalse(try store.isExcludedByCurrentRules(item: item, domainIdentifier: domainID).excluded)
        XCTAssertEqual(try store.item(identifier: item.itemIdentifier), item)
    }

    func testParentResolverFailsClosedAcrossScopeAndDepth() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-parent-resolver-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let root = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/team")
        let resolver = ParentResolver(store: store, rootURI: root.rootURI, accountID: "account", rootIdentifier: "root", maxDepth: 2)
        XCTAssertThrowsError(try resolver.resolve(parentIdentifier: "cri-11111111-1111-4111-8111-111111111111", knownURI: "cloudreve://account@my/other", hydrate: {
            RemoteItem(itemIdentifier: "cri-11111111-1111-4111-8111-111111111111", remoteID: "parent", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "other", uri: "cloudreve://account@my/other", kind: .folder, contentType: "public.folder", version: ItemVersion(content: Data(), metadata: Data()))
        })) { error in
            XCTAssertEqual(error as? ParentResolutionError, .outsideScope)
        }
    }
    func testProjectionUsesInheritedKeepPolicyAndRefreshesMetadataBoundary() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-keep-policy-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let folder = RemoteItem(remoteID: "remote-pinned-folder", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "Pinned", uri: "/Pinned", kind: .folder, contentType: "public.folder", version: ItemVersion(content: Data("folder-v1".utf8), metadata: Data("folder-m1".utf8)), canRead: true, canWrite: true, canAddChildren: true)
        let child = RemoteItem(remoteID: "remote-pinned-child", parentIdentifier: folder.itemIdentifier, name: "note.txt", uri: "/Pinned/note.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("child-v1".utf8), metadata: Data("child-m1".utf8)), canRead: true, canWrite: true)
        try store.insertItem(folder)
        try store.insertItem(child)
        try store.setKeepDownloadedPolicy(identifier: folder.itemIdentifier, policy: .keepDownloaded)
        try store.setMaterialized(child.itemIdentifier, materialized: true)

        let pinnedProjection = try XCTUnwrap(try store.itemProjection(identifier: child.itemIdentifier))
        XCTAssertEqual(pinnedProjection.effectiveKeepPolicy, .keepDownloaded)
        let pinned = NimbusSyncFileProviderItem(projection: pinnedProjection)
        XCTAssertEqual(pinned.contentPolicy, .inherited)
        XCTAssertEqual(pinned.userInfo?["keepDownloaded"] as? Bool, true)
        XCTAssertEqual(pinned.userInfo?["canEvict"] as? Bool, false)

        try store.setKeepDownloadedPolicy(identifier: folder.itemIdentifier, policy: .automatic)
        let automaticProjection = try XCTUnwrap(try store.itemProjection(identifier: child.itemIdentifier))
        let automatic = NimbusSyncFileProviderItem(projection: automaticProjection)
        XCTAssertEqual(automatic.contentPolicy, .inherited)
        XCTAssertEqual(automatic.userInfo?["keepDownloaded"] as? Bool, false)
        XCTAssertEqual(automatic.userInfo?["canEvict"] as? Bool, true)
        XCTAssertNotEqual(pinned.itemVersion.metadataVersion, automatic.itemVersion.metadataVersion)
        XCTAssertEqual(pinned.itemVersion.contentVersion, automatic.itemVersion.contentVersion)
    }

    func testExclusionViewRestorationClearsHiddenState() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-exclusion-restore-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let domainID = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: domainID, displayName: "Test", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential"))
        let item = RemoteItem(remoteID: "remote-restore", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "build.tmp", uri: "/build.tmp", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v".utf8), metadata: Data("m".utf8)), canRead: true)
        try store.insertItem(item)
        let service = ExclusionApplicationService(store: store)
        try await service.apply(try await service.preview(revision: 1, text: "*.tmp", items: [item]), domainIdentifier: domainID, preserveDirty: true)
        XCTAssertTrue(try store.localItemState(identifier: item.itemIdentifier).viewExcluded)
        try await service.apply(try await service.preview(revision: 2, text: "", items: [item]), domainIdentifier: domainID, preserveDirty: true)
        XCTAssertFalse(try store.localItemState(identifier: item.itemIdentifier).viewExcluded)
        XCTAssertEqual(try store.listChildren(parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue).map(\.itemIdentifier), [item.itemIdentifier])
    }

    func testRootScopeChangeRotatesEpochAndKeepsFreshSignalPending() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-root-epoch-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let domainID = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/team")
        try store.registerDomain(DomainDescriptor(identifier: domainID, displayName: "Test", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential"))
        let before = try store.currentAnchor(domainIdentifier: domainID, scope: NSFileProviderItemIdentifier.workingSet.rawValue)
        try store.updateDomainRootURI(identifier: domainID, rootURI: "/team-v2")
        let after = try store.currentAnchor(domainIdentifier: domainID, scope: NSFileProviderItemIdentifier.workingSet.rawValue)
        XCTAssertNotEqual(before.epoch, after.epoch)
        XCTAssertTrue(try store.syncState().reconcileStatus.hasPrefix("required:"))
        XCTAssertEqual(try store.pendingOutboxCount(), 1)
        XCTAssertThrowsError(try store.enumerateChanges(domainIdentifier: domainID, scope: NSFileProviderItemIdentifier.workingSet.rawValue, from: before)) { error in
            XCTAssertEqual(error as? StoreBridgeError, .anchorExpired)
        }
    }

    func testStaleStoreCannotWriteAfterAnotherProcessPublishesGeneration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-stale-process-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try SQLiteStateStore(url: url)
        let second = try SQLiteStateStore(url: url)
        let nextGeneration = try second.schemaFence().generation + 1
        try second.beginMigration(targetVersion: SQLiteStateStore.schemaVersion, compatibilityMinimum: SQLiteStateStore.schemaVersion, compatibilityMaximum: SQLiteStateStore.schemaVersion)
        try second.publishMigration(generation: nextGeneration)
        _ = try second.rotateSyncEpoch(reason: "peer_change")
        XCTAssertThrowsError(try first.rotateSyncEpoch(reason: "stale_after_peer_change")) { error in
            XCTAssertEqual(error as? StoreBridgeError, .schemaFenced)
        }
        XCTAssertThrowsError(try first.updateDomainRootURI(identifier: CloudreveIdentifier.domain(), rootURI: "/new-root")) { error in
            XCTAssertEqual(error as? StoreBridgeError, .schemaFenced)
        }
    }

    func testJournalFoldKeepsViewRemovalLive() {
        let item = RemoteItem(remoteID: "remote-view", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "ignored.tmp", uri: "/ignored.tmp", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v".utf8), metadata: Data("m".utf8)), canRead: true)
        let folded = JournalChangeFold.fold([ProviderChangeInput(item: item, oldParentIdentifier: item.parentIdentifier, newParentIdentifier: item.parentIdentifier, kind: "view_removed", origin: "test")])
        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(folded[0].kind, "view_removed")
        XCTAssertFalse(folded[0].item.tombstone)
    }

    func testBatchJournalCommitUsesExclusionAndViewRemovalSemantics() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-batch-journal-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let domainID = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: domainID, displayName: "Batch", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential"))
        let rules = ExclusionRuleSnapshot(revision: 3, rules: ["*.tmp"])
        try store.setPreference(key: "exclusion.rules.\(domainID)", value: String(data: try JSONEncoder().encode(rules), encoding: .utf8)!)
        let item = RemoteItem(remoteID: "remote-batch", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "ignored.tmp", uri: "/ignored.tmp", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v".utf8), metadata: Data("m".utf8)), canRead: true)

        let journals = try await EventJournalWriter(store: store).commit([
            EnrichedRemoteChange(item: item, oldParentIdentifier: nil, newParentIdentifier: item.parentIdentifier, kind: "updated")
        ])

        XCTAssertEqual(journals.count, 1)
        XCTAssertEqual(journals.first?.kind, "view_removed")
        XCTAssertTrue(try store.localItemState(identifier: item.itemIdentifier).viewExcluded)
        XCTAssertFalse(try XCTUnwrap(store.item(identifier: item.itemIdentifier)).tombstone)
    }

    func testExclusionIntentConsumptionRequiresRevisionAndGeneration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-exclusion-dimensions-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let expectedVersion = Data("version".utf8)
        let pathHash = Data("path".utf8)
        try store.createExclusionIntent(ExclusionIntent(itemIdentifier: "cri-item", systemItemIdentifier: "system-item", ruleRevision: 4, kind: .localCreate, sourceGeneration: 9, expectedVersion: expectedVersion, pathHash: pathHash))
        XCTAssertFalse(try store.consumeExclusionIntent(itemIdentifier: "cri-item", systemItemIdentifier: "system-item", kind: .localCreate, expectedVersion: expectedVersion, pathHash: pathHash, ruleRevision: 3, sourceGeneration: 9))
        XCTAssertFalse(try store.consumeExclusionIntent(itemIdentifier: "cri-item", systemItemIdentifier: "system-item", kind: .localCreate, expectedVersion: expectedVersion, pathHash: pathHash, ruleRevision: 4, sourceGeneration: 8))
        XCTAssertTrue(try store.consumeExclusionIntent(itemIdentifier: "cri-item", systemItemIdentifier: "system-item", kind: .localCreate, expectedVersion: expectedVersion, pathHash: pathHash, ruleRevision: 4, sourceGeneration: 9))
    }

    func testContinuationCodecRejectsSensitiveFields() throws {
        let page = PageToken(domainIdentifier: "https://example.com", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, snapshotGeneration: 1, offset: 0)
        XCTAssertThrowsError(try page.encoded())
        let anchor = SyncAnchor(domainIdentifier: CloudreveIdentifier.domain(), scope: "cloudreve://account@my/team", epoch: UUID(), sequence: 0)
        XCTAssertThrowsError(try anchor.encoded())
    }

    func testPageTokenValidationRejectsCrossContainerShapeAsPageExpired() throws {
        let domainID = CloudreveIdentifier.domain()
        let malformedWorkingSet = PageToken(
            domainIdentifier: domainID,
            parentIdentifier: NSFileProviderItemIdentifier.workingSet.rawValue,
            snapshotGeneration: 1,
            offset: 1,
            sort: "name",
            workingSetRevision: 4
        )
        XCTAssertThrowsError(try malformedWorkingSet.validate(domainIdentifier: domainID, parentIdentifier: NSFileProviderItemIdentifier.workingSet.rawValue))
        // pageExpired restarts enumeration from the initial page;
        // cannotSynchronize would only retry the same dead token.
        let mapped = FileProviderErrorMapper.map(StoreBridgeError.pageTokenInvalid)
        XCTAssertEqual(mapped.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(mapped.code, NSFileProviderError.pageExpired.rawValue)
        XCTAssertEqual(FileProviderErrorMapper.map(StoreBridgeError.snapshotExpired).code, NSFileProviderError.pageExpired.rawValue)
    }

    func testAsyncConflictSourceReplayCompletesConflictAndPendingState() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-async-conflict-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let domainID = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        var operations = CapabilitySnapshot.OperationCapabilities(fallbackConflict: .verified)
        operations.collisionSafeCreate = .verified
        operations.conditionalModify = .verified
        try store.registerDomain(DomainDescriptor(identifier: domainID, displayName: "Conflict", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential", capabilitySnapshot: CapabilitySnapshot(stableItemIdentity: .verified, stableRootIdentity: .verified, conditionalContentWrite: .verified, idempotentCreate: .verified, operations: operations)))
        let item = RemoteItem(remoteID: "remote-conflict", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "conflict.txt", uri: "/conflict.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("remote-v1".utf8), metadata: Data("metadata".utf8)), canRead: true, canWrite: true)
        try store.insertItem(item)
        let localData = Data("local-v2".utf8)
        let conflict = ConflictProjection(itemIdentifier: item.itemIdentifier, kind: "version_conflict", baseSummary: "base", remoteSummary: "remote", localSummary: "local", pendingItemIdentifier: item.itemIdentifier, sourceGeneration: 1, remoteVersion: item.version.content, localSourceKind: "system_pending", expectedBaseVersion: item.version.content, expectedSourceHash: Data(SHA256.hash(data: localData)), expectedSourceSize: Int64(localData.count))
        try store.saveConflict(conflict)
        try store.markConflictResolutionPending(conflictID: conflict.conflictID, itemIdentifier: item.itemIdentifier, resolution: "overwrite_remote_pending")

        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-conflict-source-\(UUID().uuidString)")
        try localData.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let backend = LegacyAsyncFileProviderBackendAdapter(backend: MemoryFileProviderBackend(items: [item], contents: [item.itemIdentifier: Data("remote".utf8)]))
        let context = FileProviderOperationContext(itemIdentifier: NSFileProviderItemIdentifier(item.itemIdentifier), progress: Progress(totalUnitCount: 1), registrar: NoopURLSessionTaskRegistrar(), cancellation: CancellationToken())
        let updated = try await AsyncFileProviderMutationCoordinator(store: store, backend: backend).modify(item: item, baseVersion: item.version.content, fields: [.contents], contents: sourceURL, options: [], context: context)

        XCTAssertEqual(updated.itemIdentifier, item.itemIdentifier)
        XCTAssertEqual(try store.pendingConflictCount(), 0)
        XCTAssertFalse(try store.hasPendingWork(itemIdentifier: item.itemIdentifier))
        XCTAssertEqual(try store.operation(replayKey: "conflict-overwrite_remote_pending|\(conflict.conflictID.uuidString)")?.operation.state, "committed")
    }

    func testAsyncConflictReplayCompletesConflictAfterCommittedOutcome() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-async-conflict-replay-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let domainID = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        var operations = CapabilitySnapshot.OperationCapabilities(fallbackConflict: .verified)
        operations.collisionSafeCreate = .verified
        operations.conditionalModify = .verified
        try store.registerDomain(DomainDescriptor(identifier: domainID, displayName: "Conflict", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential", capabilitySnapshot: CapabilitySnapshot(stableItemIdentity: .verified, stableRootIdentity: .verified, conditionalContentWrite: .verified, idempotentCreate: .verified, operations: operations)))
        let item = RemoteItem(remoteID: "remote-conflict-replay", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "conflict.txt", uri: "/conflict.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true, canWrite: true)
        try store.insertItem(item)
        let localData = Data("local-v2".utf8)
        let conflict = ConflictProjection(itemIdentifier: item.itemIdentifier, kind: "version_conflict", baseSummary: "base", remoteSummary: "remote", localSummary: "local", pendingItemIdentifier: item.itemIdentifier, sourceGeneration: 1, localSourceKind: "system_pending", expectedBaseVersion: item.version.content, expectedSourceHash: Data(SHA256.hash(data: localData)), expectedSourceSize: Int64(localData.count))
        try store.saveConflict(conflict)
        try store.markConflictResolutionPending(conflictID: conflict.conflictID, itemIdentifier: item.itemIdentifier, resolution: "overwrite_remote_pending")
        let replayKey = "conflict-overwrite_remote_pending|\(conflict.conflictID.uuidString)"
        let operation = PendingOperation(replayKey: replayKey, kind: "overwrite_remote_pending", itemIdentifier: item.itemIdentifier)
        _ = try store.upsertOperation(operation)
        try store.commitOperation(operationID: operation.operationID, state: "committed", itemIdentifier: item.itemIdentifier, outcome: String(data: try JSONEncoder().encode(item), encoding: .utf8))
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-conflict-replay-source-\(UUID().uuidString)")
        try localData.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let backend = LegacyAsyncFileProviderBackendAdapter(backend: MemoryFileProviderBackend(items: [item], contents: [item.itemIdentifier: Data("remote".utf8)]))
        let context = FileProviderOperationContext(itemIdentifier: NSFileProviderItemIdentifier(item.itemIdentifier), progress: Progress(totalUnitCount: 1), registrar: NoopURLSessionTaskRegistrar(), cancellation: CancellationToken())

        _ = try await AsyncFileProviderMutationCoordinator(store: store, backend: backend).modify(item: item, baseVersion: item.version.content, fields: [.contents], contents: sourceURL, options: [], context: context)

        XCTAssertEqual(try store.pendingConflictCount(), 0)
        XCTAssertFalse(try store.hasDirtyWork())
        XCTAssertNil(try store.pendingConflictResolution(itemIdentifier: item.itemIdentifier))
    }

    func testAsyncCreateFailurePublishesPersistentUploadError() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-create-failure-state-\(UUID().uuidString).sqlite3")
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-create-failure-source-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: sourceURL)
        }
        let store = try SQLiteStateStore(url: url)
        let itemIdentifier = CloudreveIdentifier.item()
        let template = RemoteItem(itemIdentifier: itemIdentifier, parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "new.txt", uri: "/new.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data(), metadata: Data()), canRead: true, canWrite: true)
        try Data("source".utf8).write(to: sourceURL, options: .atomic)
        let backend = LegacyAsyncFileProviderBackendAdapter(backend: FailingCreateFileProviderBackend())
        let context = FileProviderOperationContext(itemIdentifier: NSFileProviderItemIdentifier(itemIdentifier), progress: Progress(totalUnitCount: 1), registrar: NoopURLSessionTaskRegistrar(), cancellation: CancellationToken())

        do {
            _ = try await AsyncFileProviderMutationCoordinator(store: store, backend: backend).create(template: template, contents: sourceURL, fields: [.contents], options: [], context: context)
            XCTFail("the injected network failure must escape")
        } catch let failure as CoreFailure {
            XCTAssertEqual(failure.code, .network)
        }

        let state = try store.localItemState(identifier: itemIdentifier)
        XCTAssertEqual(state.uploadState, .failed)
        XCTAssertEqual(state.uploadError, CoreErrorCode.network.rawValue)
        // A transient (retryable) failure must stay replayable rather than
        // wedging the item in a terminal unknown_outcome state.
        XCTAssertEqual(try store.latestOperation(itemIdentifier: itemIdentifier)?.operation.state, "retry_pending")
    }

    func testFinalizePreservedRemovalDeletesCredentialAndDomainRecord() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-finalize-preserved-removal-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let vault = MemoryCredentialVault()
        let domainID = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        var descriptor = DomainDescriptor(identifier: domainID, displayName: "Preserved", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential")
        descriptor.status = .preservedRemoval
        try store.registerDomain(descriptor)
        try vault.write(Credential(accessToken: "token", refreshToken: "refresh", accessExpiry: Date().addingTimeInterval(3_600)), reference: descriptor.secretReference)
        let service = SafeDomainRemovalService(store: store, vault: vault, systemDomainExists: { _ in false })

        try await service.finalizePreservedRemoval(descriptor: descriptor)

        XCTAssertNil(try store.domain(identifier: domainID))
        XCTAssertNil(try vault.read(reference: descriptor.secretReference))
    }

    func testFinalizePreservedRemovalRefusesRegisteredSystemDomain() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-finalize-preserved-registered-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let vault = MemoryCredentialVault()
        let domainID = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        var descriptor = DomainDescriptor(identifier: domainID, displayName: "Registered", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential")
        descriptor.status = .preservedRemoval
        try store.registerDomain(descriptor)
        try vault.write(Credential(accessToken: "token", refreshToken: "refresh", accessExpiry: Date().addingTimeInterval(3_600)), reference: descriptor.secretReference)
        let service = SafeDomainRemovalService(store: store, vault: vault, systemDomainExists: { _ in true })

        do {
            try await service.finalizePreservedRemoval(descriptor: descriptor)
            XCTFail("a registered system Domain must not be finalized")
        } catch let error as DomainProvisioningError {
            guard case .rollbackRequired = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertNotNil(try store.domain(identifier: domainID))
        XCTAssertNotNil(try vault.read(reference: descriptor.secretReference))
    }
}

private final class FailingCreateFileProviderBackend: FileProviderBackend, @unchecked Sendable {
    func item(identifier: String) throws -> RemoteItem? { nil }
    func children(parentIdentifier: String) throws -> [RemoteItem] { [] }
    func childrenPage(parentIdentifier: String, offset: Int, limit: Int) throws -> DirectoryPage { DirectoryPage(items: [], nextOffset: nil, generation: 1, complete: true) }
    func trashItems() throws -> [RemoteItem] { [] }
    func content(identifier: String, expectedVersion: Data?) throws -> Data { throw CoreFailure(code: .notFound, retryable: false) }
    func fetchContent(identifier: String, expectedVersion: Data?, to destination: URL) throws -> RemoteItem { throw CoreFailure(code: .notFound, retryable: false) }
    func create(template: RemoteItem, content: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .network, retryable: true) }
    func modify(item: RemoteItem, expectedVersion: Data?, changedFields: NSFileProviderItemFields, content: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false) }
    func trash(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false) }
    func restore(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false) }
    func delete(identifier: String, expectedVersion: Data?, recursive: Bool) throws { throw CoreFailure(code: .unsupportedServer, retryable: false) }
}

private actor RefreshInvocationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private final class FixedRemoteEventEnricher: RemoteEventEnricher, @unchecked Sendable {
    private let change: EnrichedRemoteChange

    init(change: EnrichedRemoteChange) {
        self.change = change
    }

    func enrich(_ hint: RemoteEventHint) async throws -> EnrichedRemoteChange? {
        change
    }
}

/// The server answers that the item no longer exists, as it does after a delete.
private struct MissingRemoteEventEnricher: RemoteEventEnricher {
    func enrich(_ hint: RemoteEventHint) async throws -> EnrichedRemoteChange? { nil }
}

private actor RecordingWorkingSetSignaller: WorkingSetSignaller {
    private let shouldFail: Bool
    private var calls = 0

    init(shouldFail: Bool) {
        self.shouldFail = shouldFail
    }

    func signalWorkingSet() async throws {
        calls += 1
        if shouldFail { throw CoreFailure(code: .network, retryable: true) }
    }

    func callCount() -> Int {
        calls
    }
}

private final class LockedURLCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?

    func store(_ url: URL) {
        lock.lock(); self.url = url; lock.unlock()
    }

    func load() -> URL? {
        lock.lock(); defer { lock.unlock() }; return url
    }

    func clear() {
        lock.lock(); url = nil; lock.unlock()
    }
}

private final class RecordingEnumerationObserver: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    private let lock = NSLock()
    private let expectation: XCTestExpectation
    private(set) var items: [NSFileProviderItem] = []
    private(set) var nextPage: NSFileProviderPage?
    private(set) var error: Error?
    private let pageSize: Int

    init(suggestedPageSize: Int? = nil) {
        self.pageSize = suggestedPageSize ?? 0
        self.expectation = XCTestExpectation(description: "enumeration finishes")
    }

    var suggestedPageSize: Int { pageSize }

    func didEnumerate(_ updatedItems: [NSFileProviderItem]) {
        lock.lock()
        items.append(contentsOf: updatedItems)
        lock.unlock()
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        lock.lock()
        self.nextPage = nextPage
        lock.unlock()
        expectation.fulfill()
    }

    func finishEnumeratingWithError(_ error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
        expectation.fulfill()
    }

    func wait() async {
        _ = await XCTWaiter.fulfillment(of: [expectation], timeout: 3)
    }
}

private actor RecordingTaskRegistrar: URLSessionTaskRegistrar {
    private let shouldFail: Bool
    private var recordedStates: [URLSessionTask.State] = []

    init(shouldFail: Bool) {
        self.shouldFail = shouldFail
    }

    func registerSuspended(_ task: URLSessionTask, for itemIdentifier: NSFileProviderItemIdentifier) async throws {
        recordedStates.append(task.state)
        if shouldFail { throw CoreFailure(code: .network, retryable: true) }
    }

    func states() -> [URLSessionTask.State] { recordedStates }
}

private final class URLProtocolProbe: URLProtocol {
    private static let state = ProbeState()

    static func reset() {
        state.lock.lock()
        state.started = false
        state.lock.unlock()
    }

    static func wasStarted() -> Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.started
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.lock.lock()
        Self.state.started = true
        Self.state.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/octet-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ProbeState: @unchecked Sendable {
    let lock = NSLock()
    var started = false
}

private func waitForCapturedURL(_ capture: LockedURLCapture) async throws -> URL {
    for _ in 0..<200 {
        if let url = capture.load() { return url }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw CoreFailure(code: .unknownOutcome, retryable: false)
}
