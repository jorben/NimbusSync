import XCTest
import Foundation
import FileProvider
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveFileProviderKit

/// A stale item (its path now holds another object) cannot be trashed by path. The backend
/// deletes it instead and reports `remote_identity_changed`; the mutation must not be left
/// behind as an upload failure or an open operation, since nothing remains to retry.
final class StaleItemMutationTests: XCTestCase {
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

    func testTrashOfAStaleItemLeavesNoFailureOrOpenOperation() async throws {
        try await assertTrashLeavesNothingBehind(stage: "remote_identity_changed")
    }

    func testTrashOfAnItemWhosePathIsEmptyLeavesNoFailureOrOpenOperation() async throws {
        try await assertTrashLeavesNothingBehind(stage: "remote_path_empty")
    }

    private func assertTrashLeavesNothingBehind(stage: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-stale-mutation-\(UUID().uuidString).sqlite3")
        cleanup.append(storeURL)
        let store = try SQLiteStateStore(url: storeURL)
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: CloudreveIdentifier.domain(), displayName: "Stale", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential"))
        let stale = RemoteItem(itemIdentifier: CloudreveIdentifier.item(), remoteID: "remote-placeholder", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "index.html", uri: "/index.html", kind: .file, contentType: "public.html", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true, canWrite: true, canTrash: true)
        try store.insertItem(stale)
        var trashed = stale
        trashed.parentIdentifier = NSFileProviderItemIdentifier.trashContainer.rawValue
        let coordinator = AsyncFileProviderMutationCoordinator(store: store, backend: StaleTrashBackend(stage: stage))
        let context = FileProviderOperationContext(itemIdentifier: NSFileProviderItemIdentifier(stale.itemIdentifier), progress: Progress(totalUnitCount: 1), registrar: NoopURLSessionTaskRegistrar(), cancellation: CancellationToken())

        do {
            _ = try await coordinator.modify(item: trashed, baseVersion: stale.version.content, fields: [.parentItemIdentifier], contents: nil, options: [], context: context)
            XCTFail("the stale item cannot be trashed", file: file, line: line)
        } catch let failure as CoreFailure {
            XCTAssertTrue(failure.isRemoteObjectGone, file: file, line: line)
        }

        XCTAssertNil(try store.activeOperation(itemIdentifier: stale.itemIdentifier), "no operation is left open", file: file, line: line)
        XCTAssertEqual(try store.localItemState(identifier: stale.itemIdentifier).uploadState, LocalTransferState.none, "no upload failure is reported", file: file, line: line)
        XCTAssertFalse(try store.transferTasks().contains { $0.itemIdentifier == stale.itemIdentifier }, "no task is listed for it", file: file, line: line)
    }
}

/// Trash answers the way `NimbusSyncRemoteBackend` does for a stale item.
private final class StaleTrashBackend: CloudreveAsyncBackend, @unchecked Sendable {
    private let stage: String
    init(stage: String) { self.stage = stage }

    func create(_ request: CreateRequest, context: FileProviderOperationContext) async throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false) }
    func refreshItem(identifier: String, context: FileProviderOperationContext) async throws -> RemoteItem? { nil }
    func item(identifier: String) async throws -> RemoteItem? { nil }
    func childrenPage(parentIdentifier: String, cursor: PageCursor?) async throws -> RemotePage { throw CoreFailure(code: .unsupportedServer, retryable: false) }
    func fetchContent(identifier: String, expectedVersion: Data?, destination: URL, context: FileProviderOperationContext) async throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false) }
    func modify(_ request: ModifyRequest, context: FileProviderOperationContext) async throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false) }
    func trash(_ request: TrashRequest, context: FileProviderOperationContext) async throws -> RemoteItem {
        throw CoreFailure(code: .notFound, retryable: false, redactedContext: ["stage": stage])
    }
    func restore(_ request: RestoreRequest, context: FileProviderOperationContext) async throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false) }
    func delete(_ request: DeleteRequest, context: FileProviderOperationContext) async throws { throw CoreFailure(code: .unsupportedServer, retryable: false) }
}
