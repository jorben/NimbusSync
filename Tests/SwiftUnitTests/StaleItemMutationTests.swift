import XCTest
import Foundation
import FileProvider
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveFileProviderKit
import CloudreveProductKit

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

    /// The Quiet.md case: earlier attempts failed with an unknown outcome (Cloudreve's 40081) and
    /// left a failed transfer behind; the activity list kept showing "Outcome unknown" after a
    /// later attempt found the path empty and removed the item.
    func testEarlierUnknownOutcomeAttemptsLeaveNoRecordOnceTheItemIsGone() async throws {
        try await assertTrashLeavesNothingBehind(stage: "remote_path_empty", earlierFailures: [
            CoreFailure(code: .unknownOutcome, retryable: true),
            CoreFailure(code: .unknownOutcome, retryable: false)
        ])
    }

    private func assertTrashLeavesNothingBehind(stage: String, earlierFailures: [CoreFailure] = [], file: StaticString = #filePath, line: UInt = #line) async throws {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-stale-mutation-\(UUID().uuidString).sqlite3")
        cleanup.append(storeURL)
        let store = try SQLiteStateStore(url: storeURL)
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: CloudreveIdentifier.domain(), displayName: "Stale", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential"))
        let stale = RemoteItem(itemIdentifier: CloudreveIdentifier.item(), remoteID: "remote-placeholder", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "index.html", uri: "/index.html", kind: .file, contentType: "public.html", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true, canWrite: true, canTrash: true)
        try store.insertItem(stale)
        var trashed = stale
        trashed.parentIdentifier = NSFileProviderItemIdentifier.trashContainer.rawValue
        let backend = StaleTrashBackend(failures: earlierFailures + [CoreFailure(code: .notFound, retryable: false, redactedContext: ["stage": stage])])
        let coordinator = AsyncFileProviderMutationCoordinator(store: store, backend: backend)
        let context = FileProviderOperationContext(itemIdentifier: NSFileProviderItemIdentifier(stale.itemIdentifier), progress: Progress(totalUnitCount: 1), registrar: NoopURLSessionTaskRegistrar(), cancellation: CancellationToken())

        for _ in earlierFailures {
            // The system retries the identical callback after each failure.
            _ = try? await coordinator.modify(item: trashed, baseVersion: stale.version.content, fields: [.parentItemIdentifier], contents: nil, options: [], context: context)
        }
        if !earlierFailures.isEmpty {
            XCTAssertTrue(try store.transferTasks().contains { $0.itemIdentifier == stale.itemIdentifier && $0.state == "failed" }, "the earlier attempts left failures", file: file, line: line)
        }
        do {
            _ = try await coordinator.modify(item: trashed, baseVersion: stale.version.content, fields: [.parentItemIdentifier], contents: nil, options: [], context: context)
            XCTFail("the stale item cannot be trashed", file: file, line: line)
        } catch let failure as CoreFailure {
            XCTAssertTrue(failure.isRemoteObjectGone, file: file, line: line)
        }

        XCTAssertNil(try store.activeOperation(itemIdentifier: stale.itemIdentifier), "no operation is left open", file: file, line: line)
        XCTAssertEqual(try store.localItemState(identifier: stale.itemIdentifier).uploadState, LocalTransferState.none, "no upload failure is reported", file: file, line: line)
        XCTAssertFalse(try store.transferTasks().contains { $0.itemIdentifier == stale.itemIdentifier }, "no task is listed for it, earlier attempts included", file: file, line: line)
        XCTAssertFalse(try store.operations().contains { $0.operation.itemIdentifier == stale.itemIdentifier }, "the operation leaves the activity list", file: file, line: line)
    }

    /// A finished or cancelled operation shows no error from an earlier attempt's transfer.
    func testOnlyUnfinishedOperationsShowTheirLatestTransferError() {
        for state in ["committed", "resolved", "cancelled"] {
            XCTAssertNil(ProductTask.errorCode(forOperationState: state, latestTransferErrorCode: "unknown_outcome"), state)
        }
        XCTAssertEqual(ProductTask.errorCode(forOperationState: "retry_pending", latestTransferErrorCode: "network"), "network")
        XCTAssertEqual(ProductTask.errorCode(forOperationState: "queued", latestTransferErrorCode: nil), nil)
        XCTAssertEqual(ProductTask.errorCode(forOperationState: "unknown_outcome", latestTransferErrorCode: nil), "unknown_outcome")
        XCTAssertEqual(ProductTask.errorCode(forOperationState: "conflict", latestTransferErrorCode: "network"), "version_conflict")
        XCTAssertEqual(ProductTask.errorCode(forOperationState: "auth_expired", latestTransferErrorCode: nil), "authentication_required")
    }
}

/// Trash answers with the given failures in turn; the last is how `NimbusSyncRemoteBackend`
/// answers for a stale item.
private final class StaleTrashBackend: CloudreveAsyncBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [CoreFailure]
    init(failures: [CoreFailure]) { self.failures = failures }

    func create(_ request: CreateRequest, context: FileProviderOperationContext) async throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false) }
    func refreshItem(identifier: String, context: FileProviderOperationContext) async throws -> RemoteItem? { nil }
    func item(identifier: String) async throws -> RemoteItem? { nil }
    func childrenPage(parentIdentifier: String, cursor: PageCursor?) async throws -> RemotePage { throw CoreFailure(code: .unsupportedServer, retryable: false) }
    func fetchContent(identifier: String, expectedVersion: Data?, destination: URL, context: FileProviderOperationContext) async throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false) }
    func modify(_ request: ModifyRequest, context: FileProviderOperationContext) async throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false) }
    func trash(_ request: TrashRequest, context: FileProviderOperationContext) async throws -> RemoteItem {
        let failure = lock.withLock { failures.count > 1 ? failures.removeFirst() : failures[0] }
        throw failure
    }
    func restore(_ request: RestoreRequest, context: FileProviderOperationContext) async throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false) }
    func delete(_ request: DeleteRequest, context: FileProviderOperationContext) async throws { throw CoreFailure(code: .unsupportedServer, retryable: false) }
}
