import XCTest
import Foundation
import FileProvider
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveFileProviderKit

/// A create that committed but whose completion never reached the system is replayed, often
/// with `mayAlreadyExist` or other fields. The replay must find the committed create instead of
/// failing forever or creating the file a second time.
final class CreateReplayTests: XCTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        for url in cleanup {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        cleanup.removeAll()
        super.tearDown()
    }

    func testCommittedCreateReplayedWithOtherOptionsReturnsCommittedItem() async throws {
        let (store, template, source, backend) = try makeCreateFixture(name: "replay.txt", contents: "first")
        let coordinator = AsyncFileProviderMutationCoordinator(store: store, backend: LegacyAsyncFileProviderBackendAdapter(backend: backend))
        let created = try await coordinator.create(template: template, contents: source, fields: [.contents], options: [], context: context(template.itemIdentifier))
        XCTAssertEqual(backend.createCalls, 1)

        let replayed = try await coordinator.create(template: template, contents: source, fields: [.contents], options: [.mayAlreadyExist], context: context(template.itemIdentifier))
        XCTAssertEqual(replayed, created)

        let otherFields = try await coordinator.create(template: template, contents: source, fields: [.contents, .filename], options: [], context: context(template.itemIdentifier))
        XCTAssertEqual(otherFields, created)
        XCTAssertEqual(backend.createCalls, 1, "the committed create must not reach the server again")
    }

    func testCommittedCreateReplayedWithADifferentSourceStillFails() async throws {
        let (store, template, source, backend) = try makeCreateFixture(name: "changed.txt", contents: "first")
        let coordinator = AsyncFileProviderMutationCoordinator(store: store, backend: LegacyAsyncFileProviderBackendAdapter(backend: backend))
        _ = try await coordinator.create(template: template, contents: source, fields: [.contents], options: [], context: context(template.itemIdentifier))
        try Data("second".utf8).write(to: source, options: .atomic)

        do {
            _ = try await coordinator.create(template: template, contents: source, fields: [.contents], options: [.mayAlreadyExist], context: context(template.itemIdentifier))
            XCTFail("a committed create must not be matched by a different source")
        } catch let failure as CoreFailure {
            XCTAssertEqual(failure.code, .unknownOutcome)
        }
        XCTAssertEqual(backend.createCalls, 1)
    }

    func testUnknownOutcomeFolderCreateReplayAdoptsTheExistingRemoteFolder() async throws {
        for replayOptions in [NSFileProviderCreateItemOptions(), .mayAlreadyExist] {
            let (store, template, backend) = try await makeLostFolderCreate(name: "Folder")
            backend.setRefreshResult(backend.firstCreated)
            let coordinator = AsyncFileProviderMutationCoordinator(store: store, backend: backend)

            let replayed = try await coordinator.create(template: template, contents: nil, fields: [], options: replayOptions, context: context(template.itemIdentifier))
            XCTAssertEqual(replayed.remoteID, "remote-folder")
            XCTAssertEqual(backend.createCalls, 1, "a replay must not create a second remote folder")
            XCTAssertEqual(try store.latestOperation(itemIdentifier: template.itemIdentifier)?.operation.state, "committed")
            XCTAssertEqual(try store.item(identifier: template.itemIdentifier)?.remoteID, "remote-folder")
        }
    }

    func testUnknownOutcomeFolderCreateReplayCreatesAgainWhenTheRemoteFolderIsGone() async throws {
        let (store, template, backend) = try await makeLostFolderCreate(name: "Gone")
        backend.setRefreshResult(nil)
        let coordinator = AsyncFileProviderMutationCoordinator(store: store, backend: backend)

        let replayed = try await coordinator.create(template: template, contents: nil, fields: [], options: [], context: context(template.itemIdentifier))
        XCTAssertEqual(backend.createCalls, 2)
        XCTAssertEqual(replayed.name, "Gone")
        XCTAssertEqual(try store.latestOperation(itemIdentifier: template.itemIdentifier)?.operation.state, "committed")
    }

    func testUnknownOutcomeFolderCreateReplayNameCollisionIsUnknownOutcome() async throws {
        let (store, template, backend) = try await makeLostFolderCreate(name: "Moved")
        var elsewhere = try XCTUnwrap(backend.firstCreated)
        elsewhere.name = "Moved elsewhere"
        backend.setRefreshResult(elsewhere)
        backend.setCreateFailure(CoreFailure(code: .nameCollision, retryable: false, userActionRequired: true))
        let coordinator = AsyncFileProviderMutationCoordinator(store: store, backend: backend)

        do {
            _ = try await coordinator.create(template: template, contents: nil, fields: [], options: [], context: context(template.itemIdentifier))
            XCTFail("an unproven replay must not succeed")
        } catch let failure as CoreFailure {
            XCTAssertEqual(failure.code, .unknownOutcome)
        }
        XCTAssertEqual(backend.createCalls, 2)
    }

    func testMayAlreadyExistCreateNameCollisionIsUnknownOutcome() async throws {
        let (store, template) = try makeFolderFixture(name: "Maybe")
        let backend = ScriptedCreateBackend()
        backend.setCreateFailure(CoreFailure(code: .nameCollision, retryable: false, userActionRequired: true))
        let coordinator = AsyncFileProviderMutationCoordinator(store: store, backend: backend)

        do {
            _ = try await coordinator.create(template: template, contents: nil, fields: [], options: [.mayAlreadyExist], context: context(template.itemIdentifier))
            XCTFail("a mayAlreadyExist create must not report a filename collision")
        } catch let failure as CoreFailure {
            XCTAssertEqual(failure.code, .unknownOutcome)
        }
    }

    func testFirstCreateNameCollisionStaysNameCollision() async throws {
        let (store, template) = try makeFolderFixture(name: "Taken")
        let backend = ScriptedCreateBackend()
        backend.setCreateFailure(CoreFailure(code: .nameCollision, retryable: false, userActionRequired: true))
        let coordinator = AsyncFileProviderMutationCoordinator(store: store, backend: backend)

        do {
            _ = try await coordinator.create(template: template, contents: nil, fields: [], options: [], context: context(template.itemIdentifier))
            XCTFail("a genuine name clash must be reported")
        } catch let failure as CoreFailure {
            XCTAssertEqual(failure.code, .nameCollision)
        }
    }

    func testCommittedCreateReplayedWithARenamedTemplateFails() async throws {
        let (store, template, source, backend) = try makeCreateFixture(name: "before.txt", contents: "first")
        let coordinator = AsyncFileProviderMutationCoordinator(store: store, backend: LegacyAsyncFileProviderBackendAdapter(backend: backend))
        _ = try await coordinator.create(template: template, contents: source, fields: [.contents], options: [], context: context(template.itemIdentifier))
        var renamed = template
        renamed.name = "after.txt"
        renamed.uri = "/after.txt"

        do {
            let result = try await coordinator.create(template: renamed, contents: source, fields: [.contents, .filename], options: [.mayAlreadyExist], context: context(template.itemIdentifier))
            XCTFail("a renamed replay must not get the old name back, got \(result.name)")
        } catch let failure as CoreFailure {
            XCTAssertEqual(failure.code, .unknownOutcome)
        }
        XCTAssertEqual(backend.createCalls, 1)
    }

    /// The first folder create reaches the server, but the callback is cancelled before its
    /// completion, so the operation is left `unknown_outcome` with the remote ID stored.
    private func makeLostFolderCreate(name: String) async throws -> (SQLiteStateStore, RemoteItem, ScriptedCreateBackend) {
        let (store, template) = try makeFolderFixture(name: name)
        let backend = ScriptedCreateBackend()
        let cancellation = CancellationToken()
        backend.cancelOnFirstCreate(cancellation)
        let firstContext = FileProviderOperationContext(itemIdentifier: NSFileProviderItemIdentifier(template.itemIdentifier), progress: Progress(totalUnitCount: 1), registrar: NoopURLSessionTaskRegistrar(), cancellation: cancellation)
        let coordinator = AsyncFileProviderMutationCoordinator(store: store, backend: backend)
        do {
            _ = try await coordinator.create(template: template, contents: nil, fields: [], options: [], context: firstContext)
            XCTFail("the cancelled create must not complete")
        } catch let failure as CoreFailure {
            XCTAssertEqual(failure.code, .unknownOutcome)
        }
        XCTAssertEqual(try store.latestOperation(itemIdentifier: template.itemIdentifier)?.operation.state, "unknown_outcome")
        XCTAssertEqual(try store.item(identifier: template.itemIdentifier)?.remoteID, "remote-folder")
        return (store, template, backend)
    }

    private func makeFolderFixture(name: String) throws -> (SQLiteStateStore, RemoteItem) {
        let store = try SQLiteStateStore(url: temporaryURL("store.sqlite3"))
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: CloudreveIdentifier.domain(), displayName: "Replay", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential"))
        let template = RemoteItem(itemIdentifier: CloudreveIdentifier.item(), parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: name, uri: "/\(name)", kind: .folder, contentType: "public.folder", version: ItemVersion(content: Data(), metadata: Data()), canRead: true, canWrite: true, canAddChildren: true)
        return (store, template)
    }

    private func makeCreateFixture(name: String, contents: String) throws -> (SQLiteStateStore, RemoteItem, URL, CountingCreateBackend) {
        let storeURL = temporaryURL("store.sqlite3")
        let store = try SQLiteStateStore(url: storeURL)
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: CloudreveIdentifier.domain(), displayName: "Replay", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential"))
        let template = RemoteItem(itemIdentifier: CloudreveIdentifier.item(), parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: name, uri: "/\(name)", kind: .file, contentType: "public.data", version: ItemVersion(content: Data(), metadata: Data()), canRead: true, canWrite: true)
        let source = temporaryURL(name)
        try Data(contents.utf8).write(to: source, options: .atomic)
        return (store, template, source, CountingCreateBackend())
    }

    private func temporaryURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-create-replay-\(UUID().uuidString)-\(name)")
        cleanup.append(url)
        return url
    }

    private func context(_ identifier: String) -> FileProviderOperationContext {
        FileProviderOperationContext(itemIdentifier: NSFileProviderItemIdentifier(identifier), progress: Progress(totalUnitCount: 1), registrar: NoopURLSessionTaskRegistrar(), cancellation: CancellationToken())
    }
}

private final class CountingCreateBackend: FileProviderBackend, @unchecked Sendable {
    private let memory = MemoryFileProviderBackend()
    private let lock = NSLock()
    private var createCallCount = 0

    var createCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return createCallCount
    }

    func item(identifier: String) throws -> RemoteItem? { try memory.item(identifier: identifier) }
    func children(parentIdentifier: String) throws -> [RemoteItem] { try memory.children(parentIdentifier: parentIdentifier) }
    func childrenPage(parentIdentifier: String, offset: Int, limit: Int) throws -> DirectoryPage { try memory.childrenPage(parentIdentifier: parentIdentifier, offset: offset, limit: limit) }
    func trashItems() throws -> [RemoteItem] { try memory.trashItems() }
    func content(identifier: String, expectedVersion: Data?) throws -> Data { try memory.content(identifier: identifier, expectedVersion: expectedVersion) }
    func create(template: RemoteItem, content: Data?, replayKey: String) throws -> RemoteItem {
        lock.lock()
        createCallCount += 1
        lock.unlock()
        return try memory.create(template: template, content: content, replayKey: replayKey)
    }
    func modify(item: RemoteItem, expectedVersion: Data?, changedFields: NSFileProviderItemFields, content: Data?, replayKey: String) throws -> RemoteItem { try memory.modify(item: item, expectedVersion: expectedVersion, changedFields: changedFields, content: content, replayKey: replayKey) }
    func trash(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { try memory.trash(item: item, expectedVersion: expectedVersion, replayKey: replayKey) }
    func restore(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { try memory.restore(item: item, expectedVersion: expectedVersion, replayKey: replayKey) }
    func delete(identifier: String, expectedVersion: Data?, recursive: Bool) throws { try memory.delete(identifier: identifier, expectedVersion: expectedVersion, recursive: recursive) }
}

/// Answers `create` and `refreshItem` the way a Cloudreve server would after a create whose
/// completion was lost.
private final class ScriptedCreateBackend: CloudreveAsyncBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var createCallCount = 0
    private var firstCreatedItem: RemoteItem?
    private var refreshResult: RemoteItem?
    private var createFailure: CoreFailure?
    private var cancellationOnFirstCreate: CancellationToken?

    var createCalls: Int { locked { createCallCount } }
    var firstCreated: RemoteItem? { locked { firstCreatedItem } }
    func setRefreshResult(_ item: RemoteItem?) { locked { refreshResult = item } }
    func setCreateFailure(_ failure: CoreFailure?) { locked { createFailure = failure } }
    func cancelOnFirstCreate(_ token: CancellationToken) { locked { cancellationOnFirstCreate = token } }

    func create(_ request: CreateRequest, context: FileProviderOperationContext) async throws -> RemoteItem {
        let (failure, cancellation, attempt): (CoreFailure?, CancellationToken?, Int) = locked {
            createCallCount += 1
            let token = cancellationOnFirstCreate
            cancellationOnFirstCreate = nil
            return (createFailure, token, createCallCount)
        }
        if let failure { throw failure }
        var item = request.template
        item.remoteID = attempt == 1 ? "remote-folder" : "remote-folder-\(attempt)"
        locked { if firstCreatedItem == nil { firstCreatedItem = item } }
        cancellation?.cancel()
        return item
    }

    func refreshItem(identifier: String, context: FileProviderOperationContext) async throws -> RemoteItem? { locked { refreshResult } }
    func item(identifier: String) async throws -> RemoteItem? { locked { refreshResult } }
    func childrenPage(parentIdentifier: String, cursor: PageCursor?) async throws -> RemotePage { throw CoreFailure(code: .unsupportedServer, retryable: false) }
    func fetchContent(identifier: String, expectedVersion: Data?, destination: URL, context: FileProviderOperationContext) async throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false) }
    func modify(_ request: ModifyRequest, context: FileProviderOperationContext) async throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false) }
    func trash(_ request: TrashRequest, context: FileProviderOperationContext) async throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false) }
    func restore(_ request: RestoreRequest, context: FileProviderOperationContext) async throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false) }
    func delete(_ request: DeleteRequest, context: FileProviderOperationContext) async throws { throw CoreFailure(code: .unsupportedServer, retryable: false) }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
