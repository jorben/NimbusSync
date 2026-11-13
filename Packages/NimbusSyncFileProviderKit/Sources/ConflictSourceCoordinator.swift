import Foundation
import FileProvider
import CloudreveDomainKit
import CloudreveStoreBridge

/// Implements the old-macOS user-export fallback without persisting a path,
/// bookmark, callback URL, or file contents. The caller owns the visible
/// Save/Open panel and passes only the selected destination/source URL.
public final class ConflictSourceExportCoordinator: @unchecked Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    @available(macOS 13.0, *)
    public func export(conflict: ConflictProjection, manager: NSFileProviderManager, destination: URL) async throws -> ConflictSourceRecord {
        guard destination.isFileURL,
              let expectedHash = conflict.expectedSourceHash,
              let expectedSize = conflict.expectedSourceSize else {
            throw CoreFailure(code: .awaitingSourceReplay, retryable: false, userActionRequired: true)
        }
        let sourceURL = try await userVisibleURL(manager: manager, itemIdentifier: conflict.itemIdentifier)
        let sourcePath = sourceURL.resolvingSymlinksInPath().standardizedFileURL.path
        let destinationPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard sourcePath != destinationPath else {
            throw CoreFailure(code: .invalidName, retryable: false, userActionRequired: true)
        }
        let startedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if startedAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: sourceURL, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
            do {
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: nil)
                }
                try FileManager.default.copyItem(at: coordinatedURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let copyError { throw copyError }
        if let coordinationError { throw coordinationError }

        let fingerprint: (hash: Data, size: Int64)
        do {
            fingerprint = try FileProviderSourceFingerprint.digest(url: destination)
        } catch {
            throw CoreFailure(code: .awaitingSourceReplay, retryable: false, userActionRequired: true)
        }
        guard fingerprint.hash == expectedHash, fingerprint.size == expectedSize else {
            throw CoreFailure(code: .awaitingSourceReplay, retryable: false, userActionRequired: true, redactedContext: ["stage": "export_source_mismatch"])
        }
        let record = ConflictSourceRecord(kind: "user_export", sourceGeneration: max(1, conflict.sourceGeneration), expectedBaseVersion: conflict.expectedBaseVersion, expectedHash: fingerprint.hash, expectedSize: fingerprint.size)
        try store.setConflictSource(conflictID: conflict.conflictID, source: record)
        return record
    }

    @available(macOS 13.0, *)
    private func userVisibleURL(manager: NSFileProviderManager, itemIdentifier: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(itemIdentifier)) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url, url.isFileURL, !url.path.isEmpty {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: CoreFailure(code: .awaitingSourceReplay, retryable: false, userActionRequired: true))
                }
            }
        }
    }
}
