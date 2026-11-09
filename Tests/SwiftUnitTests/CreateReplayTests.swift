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
