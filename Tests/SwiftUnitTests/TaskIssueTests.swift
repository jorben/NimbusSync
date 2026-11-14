import XCTest
import CloudreveDesignSystem
import CloudreveDomainKit
import CloudreveFileProviderKit
import CloudreveProductKit
import CloudreveStoreBridge

/// The popover lists failures as issues with a retry button. A failure that later went through,
/// or one the app cannot start again, must not sit there with a button that does nothing.
final class TaskIssueTests: EnglishLocalizationTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    func testDownloadFailureDisappearsOnceTheSameFileDownloads() {
        let failed = ProductTask(domainIdentifier: "d", itemIdentifier: "item", title: "Q3.pdf", direction: .download, state: .failed, errorCode: "cannot_synchronize", updatedAt: base)
        let succeeded = ProductTask(domainIdentifier: "d", itemIdentifier: "item", title: "Q3.pdf", direction: .download, state: .succeeded, updatedAt: base)
        XCTAssertEqual(ProductTask.droppingSupersededFailures([succeeded, failed]).map(\.id), [succeeded.id], "a success in the same second supersedes it")

        let later = ProductTask(domainIdentifier: "d", itemIdentifier: "item", title: "Q3.pdf", direction: .download, state: .failed, updatedAt: base.addingTimeInterval(60))
        XCTAssertEqual(Set(ProductTask.droppingSupersededFailures([later, succeeded]).map(\.id)), [later.id, succeeded.id], "a failure after the success is news")
    }

    func testOnlyTheSameItemDirectionAndDomainSupersede() {
        let failed = ProductTask(domainIdentifier: "d", itemIdentifier: "item", title: "a", direction: .download, state: .failed, updatedAt: base)
        let tasks = [
            failed,
            ProductTask(domainIdentifier: "d", itemIdentifier: "other", title: "b", direction: .download, state: .succeeded, updatedAt: base.addingTimeInterval(1)),
            ProductTask(domainIdentifier: "d", itemIdentifier: "item", title: "a", direction: .upload, state: .succeeded, updatedAt: base.addingTimeInterval(1)),
            ProductTask(domainIdentifier: "e", itemIdentifier: "item", title: "a", direction: .download, state: .succeeded, updatedAt: base.addingTimeInterval(1))
        ]
        XCTAssertTrue(ProductTask.droppingSupersededFailures(tasks).contains { $0.id == failed.id })
    }

    func testRetryableFailuresStayForTheUserToDecide() {
        let failed = ProductTask(domainIdentifier: "d", itemIdentifier: "item", title: "a", direction: .upload, state: .failed, updatedAt: base, retryable: true)
        let succeeded = ProductTask(domainIdentifier: "d", itemIdentifier: "item", title: "a", direction: .upload, state: .succeeded, updatedAt: base.addingTimeInterval(1))
        XCTAssertEqual(ProductTask.droppingSupersededFailures([succeeded, failed]).count, 2)
    }

    func testRetryButtonOnlyForWorkTheAppCanRunAgain() {
        let download = TaskDisplay(id: UUID(), title: "Q3.pdf", progress: nil, detail: "cannot_synchronize", state: "failed", retryable: false)
        XCTAssertTrue(download.isIssue)
        XCTAssertFalse(download.canRetry)
        XCTAssertTrue(TaskDisplay(id: UUID(), title: "Q3.pdf", progress: nil, detail: "network", state: "failed").canRetry)
    }

    func testEveryIssueCanBeClearedButNothingElse() {
        XCTAssertTrue(TaskDisplay(id: UUID(), title: "a", progress: nil, detail: "network", state: "failed", retryable: false).canClear)
        XCTAssertTrue(TaskDisplay(id: UUID(), title: "a", progress: nil, detail: "version_conflict", state: "action_required").canClear)
        XCTAssertFalse(TaskDisplay(id: UUID(), title: "a", progress: nil, detail: "succeeded", state: "succeeded").canClear)
        XCTAssertFalse(TaskDisplay(id: UUID(), title: "a", progress: 0.5, detail: "running", state: "running").canClear)
    }

    /// A download the system started is retried by asking the system again, not through the
    /// operation queue; an operation, or a download with no item, is not one of those.
    func testSystemDownloadIsADownloadOutsideTheOperationQueue() {
        XCTAssertTrue(ProductTask(domainIdentifier: "d", itemIdentifier: "item", title: "a", direction: .download, state: .failed).isSystemDownload)
        XCTAssertFalse(ProductTask(domainIdentifier: "d", itemIdentifier: nil, title: "a", direction: .download, state: .failed).isSystemDownload)
        XCTAssertFalse(ProductTask(domainIdentifier: "d", itemIdentifier: "item", title: "a", direction: .upload, state: .failed).isSystemDownload)
        XCTAssertFalse(ProductTask(domainIdentifier: "d", itemIdentifier: "item", title: "a", direction: .download, state: .failed, retryable: true).isSystemDownload)
    }

    /// The server no longer having the item is not something asking again changes.
    func testNotFoundCanBeClearedButNotRetried() {
        let gone = TaskDisplay(id: UUID(), title: "a", progress: nil, detail: "not_found", state: "failed")
        XCTAssertFalse(gone.canRetry)
        XCTAssertTrue(gone.canClear)
    }

    /// A new download replaces the item's earlier failures instead of stacking up beside them.
    func testNewDownloadForgetsOnlyThatItemsFailedDownloads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("task-issue-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let operation = try store.upsertOperation(PendingOperation(replayKey: "modify|item", kind: "modify", itemIdentifier: "item"))
        var kept: [UUID] = []
        for _ in 0..<2 {
            let failed = try store.createTransferTask(operationID: nil, itemIdentifier: "item", direction: "download", totalBytes: nil)
            try store.updateTransferTask(taskID: failed.taskID, state: "failed", bytes: 0, totalBytes: nil, errorCode: "not_found")
        }
        kept.append(try store.createTransferTask(operationID: nil, itemIdentifier: "item", direction: "download", totalBytes: nil).taskID)
        let upload = try store.createTransferTask(operationID: nil, itemIdentifier: "item", direction: "upload", totalBytes: nil)
        try store.updateTransferTask(taskID: upload.taskID, state: "failed", bytes: 0, totalBytes: nil, errorCode: "network")
        kept.append(upload.taskID)
        let other = try store.createTransferTask(operationID: nil, itemIdentifier: "other", direction: "download", totalBytes: nil)
        try store.updateTransferTask(taskID: other.taskID, state: "failed", bytes: 0, totalBytes: nil, errorCode: "network")
        kept.append(other.taskID)
        let queued = try store.createTransferTask(operationID: operation.operationID, itemIdentifier: "item", direction: "download", totalBytes: nil)
        try store.updateTransferTask(taskID: queued.taskID, state: "failed", bytes: 0, totalBytes: nil, errorCode: "network")
        kept.append(queued.taskID)

        try store.deleteFailedTransferTasks(itemIdentifier: "item", direction: "download")
        XCTAssertEqual(Set(try store.transferTasks().map(\.taskID)), Set(kept))
    }

    /// Clearing an operation only hides it; running it again shows it again.
    func testClearedOperationReturnsWhenRetriedOrReplayed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("task-issue-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let failed = try store.upsertOperation(PendingOperation(replayKey: "modify|failed", kind: "modify", itemIdentifier: "item", state: "permanently_failed"))
        let conflict = try store.upsertOperation(PendingOperation(replayKey: "modify|conflict", kind: "modify", itemIdentifier: "other", state: "conflict"))

        try store.hideOperationFromHistory(operationID: failed.operationID)
        try store.hideOperationFromHistory(operationID: conflict.operationID)
        XCTAssertTrue(try store.operations().isEmpty)
        XCTAssertEqual(try store.operation(operationID: failed.operationID)?.operation.state, "permanently_failed", "clearing leaves the state alone")

        try store.retryOperation(operationID: failed.operationID)
        XCTAssertEqual(try store.operations().map(\.operation.operationID), [failed.operationID])

        try store.reopenOperation(replayKey: "modify|conflict")
        XCTAssertEqual(Set(try store.operations().map(\.operation.operationID)), [failed.operationID, conflict.operationID])
    }

    /// Finder asking for a file twice at once turns the second request away; that is not a
    /// failure of the file, and a deleted task leaves nothing for the popover to list.
    func testOnlyTheAlreadyRegisteredRejectionIsTreatedAsDuplicate() throws {
        XCTAssertTrue(CoreFailure(code: .cannotSynchronize, retryable: true, userActionRequired: true, redactedContext: ["stage": "task_already_registered"]).isAlreadyRegisteredTransfer)
        XCTAssertFalse(CoreFailure(code: .cannotSynchronize, retryable: false, userActionRequired: true, redactedContext: ["stage": "task_not_suspended"]).isAlreadyRegisteredTransfer)
        XCTAssertFalse(CoreFailure(code: .network, retryable: true, redactedContext: ["stage": "task_already_registered"]).isAlreadyRegisteredTransfer)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("task-issue-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let kept = try store.createTransferTask(operationID: nil, itemIdentifier: "item", direction: "download", totalBytes: nil)
        let duplicate = try store.createTransferTask(operationID: nil, itemIdentifier: "item", direction: "download", totalBytes: nil)
        try store.deleteTransferTask(taskID: duplicate.taskID)
        XCTAssertEqual(try store.transferTasks().map(\.taskID), [kept.taskID])
    }
}
