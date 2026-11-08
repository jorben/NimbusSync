import XCTest
import CloudreveDesignSystem
import CloudreveDomainKit
import CloudreveFileProviderKit
import CloudreveProductKit
import CloudreveStoreBridge

/// The popover lists failures as issues with a retry button. A failure that later went through,
/// or one the app cannot start again, must not sit there with a button that does nothing.
final class TaskIssueTests: XCTestCase {
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
