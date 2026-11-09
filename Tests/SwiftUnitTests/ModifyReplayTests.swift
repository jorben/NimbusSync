import XCTest
import Foundation
import FileProvider
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveFileProviderKit

/// A rename or move leaves the content version alone. Two such requests for the same item used
/// to share a replay key, so the second was answered with the first one's stored result without
/// reaching the server: renaming a new folder to `Quiet` and then to `Quiet.md` left it `Quiet`
/// on the server, and the system renamed it back locally. Only the system replaying the identical
/// callback may be answered from the stored result.
final class ModifyReplayTests: XCTestCase {
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

    func testSecondRenameOfAnUnchangedItemReachesTheServer() async throws {
        let (store, folder, backend) = try makeFixture()
        let coordinator = AsyncFileProviderMutationCoordinator(store: store, backend: LegacyAsyncFileProviderBackendAdapter(backend: backend))

        let first = try await coordinator.modify(item: renamed(folder, "Quiet"), baseVersion: folder.version.content, fields: [.filename], contents: nil, options: [], context: context(folder))
        let second = try await coordinator.modify(item: renamed(first, "Quiet.md"), baseVersion: first.version.content, fields: [.filename], contents: nil, options: [], context: context(folder))

        XCTAssertEqual(first.name, "Quiet")
        XCTAssertEqual(second.name, "Quiet.md")
        XCTAssertEqual(try backend.item(identifier: folder.itemIdentifier)?.name, "Quiet.md", "the second rename reached the server")
        XCTAssertEqual(backend.modifyCalls, 2)
    }

    /// The base metadata version tells repeated requests for the same name apart: renaming back and
    /// forth must reach the server every time, not answer the third request with the first result.
    func testRenamingBackAndForthReachesTheServerEveryTime() async throws {
        let (store, folder, backend) = try makeFixture()
        let coordinator = AsyncFileProviderMutationCoordinator(store: store, backend: LegacyAsyncFileProviderBackendAdapter(backend: backend))

        for (step, name) in ["B", "A", "B"].enumerated() {
            let current = try XCTUnwrap(try store.item(identifier: folder.itemIdentifier))
            let result = try await coordinator.modify(item: renamed(current, name), baseVersion: current.version.content, baseMetadataVersion: Data("meta-\(step)".utf8), fields: [.filename], contents: nil, options: [], context: context(folder))
            XCTAssertEqual(result.name, name, "step \(step)")
            XCTAssertEqual(try backend.item(identifier: folder.itemIdentifier)?.name, name, "step \(step) reached the server")
        }
        XCTAssertEqual(backend.modifyCalls, 3)
    }

    /// A move and a following trash both change only the parent.
    func testMoveThenTrashBothReachTheServer() async throws {
        let (store, folder, backend) = try makeFixture()
        let destination = RemoteItem(itemIdentifier: CloudreveIdentifier.item(), remoteID: "remote-destination", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "Destination", uri: "/Destination", kind: .folder, contentType: "public.folder", version: ItemVersion(content: Data("d".utf8), metadata: Data("d".utf8)), canRead: true, canWrite: true, canAddChildren: true)
        try store.insertItem(destination)
        backend.insert(destination)
        let coordinator = AsyncFileProviderMutationCoordinator(store: store, backend: LegacyAsyncFileProviderBackendAdapter(backend: backend))

        var moved = folder
        moved.parentIdentifier = destination.itemIdentifier
        let afterMove = try await coordinator.modify(item: moved, baseVersion: folder.version.content, fields: [.parentItemIdentifier], contents: nil, options: [], context: context(folder))
        XCTAssertEqual(afterMove.parentIdentifier, destination.itemIdentifier)

        var trashed = afterMove
        trashed.parentIdentifier = NSFileProviderItemIdentifier.trashContainer.rawValue
        let afterTrash = try await coordinator.modify(item: trashed, baseVersion: afterMove.version.content, fields: [.parentItemIdentifier], contents: nil, options: [], context: context(folder))

        XCTAssertTrue(afterTrash.trashed, "the trash was not answered with the move's result")
        XCTAssertEqual(try backend.item(identifier: folder.itemIdentifier)?.trashed, true)
    }

    func testReplayOfTheIdenticalCallbackIsAnsweredFromTheStoredResult() async throws {
        let (store, folder, backend) = try makeFixture()
        let coordinator = AsyncFileProviderMutationCoordinator(store: store, backend: LegacyAsyncFileProviderBackendAdapter(backend: backend))
        let request = renamed(folder, "Quiet.md")

        let first = try await coordinator.modify(item: request, baseVersion: folder.version.content, baseMetadataVersion: folder.version.metadata, fields: [.filename], contents: nil, options: [], context: context(folder))
        let replay = try await coordinator.modify(item: request, baseVersion: folder.version.content, baseMetadataVersion: folder.version.metadata, fields: [.filename], contents: nil, options: [], context: context(folder))

        XCTAssertEqual(first.name, "Quiet.md")
        XCTAssertEqual(replay.name, "Quiet.md")
        XCTAssertEqual(backend.modifyCalls, 1, "the system replaying the same callback does not rename twice")
    }

    func testSynchronousCoordinatorAlsoSendsTheSecondRename() throws {
        let (store, folder, backend) = try makeFixture()
        let coordinator = FileProviderMutationCoordinator(store: store, backend: backend)
        let base = NSFileProviderItemVersion(contentVersion: folder.version.content, metadataVersion: folder.version.metadata)

        let first = try coordinator.modify(item: renamed(folder, "Quiet"), baseVersion: base, fields: [.filename], contents: nil, options: [])
        let second = try coordinator.modify(item: renamed(first, "Quiet.md"), baseVersion: base, fields: [.filename], contents: nil, options: [])

        XCTAssertEqual(second.name, "Quiet.md")
        XCTAssertEqual(try backend.item(identifier: folder.itemIdentifier)?.name, "Quiet.md")
    }

    // MARK: - Fixture

    private func makeFixture() throws -> (SQLiteStateStore, RemoteItem, CountingModifyBackend) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-modify-replay-\(UUID().uuidString).sqlite3")
        cleanup.append(url)
        let store = try SQLiteStateStore(url: url)
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: CloudreveIdentifier.domain(), displayName: "Replay", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential"))
        let folder = RemoteItem(itemIdentifier: CloudreveIdentifier.item(), remoteID: "remote-folder", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "Untitled", uri: "/Untitled", kind: .folder, contentType: "public.folder", version: ItemVersion(content: Data("c".utf8), metadata: Data("m".utf8)), canRead: true, canWrite: true, canAddChildren: true, canTrash: true)
        try store.insertItem(folder)
        return (store, folder, CountingModifyBackend(items: [folder]))
    }

    private func renamed(_ item: RemoteItem, _ name: String) -> RemoteItem {
        var item = item
        item.name = name
        return item
    }

    private func context(_ item: RemoteItem) -> FileProviderOperationContext {
        FileProviderOperationContext(itemIdentifier: NSFileProviderItemIdentifier(item.itemIdentifier), progress: Progress(totalUnitCount: 1), registrar: NoopURLSessionTaskRegistrar(), cancellation: CancellationToken())
    }
}

/// The in-memory backend, counting modify calls (what would reach the server).
private final class CountingModifyBackend: FileProviderBackend, @unchecked Sendable {
    private var memory: MemoryFileProviderBackend
    private var items: [RemoteItem]
    private let lock = NSLock()
    private var modifyCallCount = 0

    init(items: [RemoteItem]) {
        self.items = items
        self.memory = MemoryFileProviderBackend(items: items)
    }

    var modifyCalls: Int { lock.lock(); defer { lock.unlock() }; return modifyCallCount }

    /// Adds an item before any mutation (the in-memory backend takes its items at init).
    func insert(_ item: RemoteItem) {
        items.append(item)
        memory = MemoryFileProviderBackend(items: items)
    }

    func item(identifier: String) throws -> RemoteItem? { try memory.item(identifier: identifier) }
    func children(parentIdentifier: String) throws -> [RemoteItem] { try memory.children(parentIdentifier: parentIdentifier) }
    func childrenPage(parentIdentifier: String, offset: Int, limit: Int) throws -> DirectoryPage { try memory.childrenPage(parentIdentifier: parentIdentifier, offset: offset, limit: limit) }
    func trashItems() throws -> [RemoteItem] { try memory.trashItems() }
    func content(identifier: String, expectedVersion: Data?) throws -> Data { try memory.content(identifier: identifier, expectedVersion: expectedVersion) }
    func fetchContent(identifier: String, expectedVersion: Data?, to destination: URL) throws -> RemoteItem { try memory.fetchContent(identifier: identifier, expectedVersion: expectedVersion, to: destination) }
    func create(template: RemoteItem, content: Data?, replayKey: String) throws -> RemoteItem { try memory.create(template: template, content: content, replayKey: replayKey) }
    func modify(item: RemoteItem, expectedVersion: Data?, changedFields: NSFileProviderItemFields, content: Data?, replayKey: String) throws -> RemoteItem {
        lock.lock()
        modifyCallCount += 1
        lock.unlock()
        return try memory.modify(item: item, expectedVersion: expectedVersion, changedFields: changedFields, content: content, replayKey: replayKey)
    }
    func trash(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { try memory.trash(item: item, expectedVersion: expectedVersion, replayKey: replayKey) }
    func restore(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { try memory.restore(item: item, expectedVersion: expectedVersion, replayKey: replayKey) }
    func delete(identifier: String, expectedVersion: Data?, recursive: Bool) throws { try memory.delete(identifier: identifier, expectedVersion: expectedVersion, recursive: recursive) }
}
