import Foundation
import FileProvider
import CryptoKit
import CloudreveDomainKit
import CloudreveStoreBridge

public struct ModifyOutcome: Sendable {
    public let item: RemoteItem
    /// The returned item's content differs from the local bytes (the local
    /// edit was preserved as a conflict copy); the system must re-download.
    public let shouldFetchContent: Bool
    public let conflictCopy: RemoteItem?
    public init(item: RemoteItem, shouldFetchContent: Bool = false, conflictCopy: RemoteItem? = nil) {
        self.item = item
        self.shouldFetchContent = shouldFetchContent
        self.conflictCopy = conflictCopy
    }
}

/// "report.docx" → "report (Conflict 2026-11-08 172233).docx"
public enum ConflictCopyNaming {
    public static func name(for original: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let stamp = formatter.string(from: date)
        let ns = original as NSString
        let ext = ns.pathExtension
        let base = ext.isEmpty ? original : ns.deletingPathExtension
        let suffix = " (Conflict \(stamp))"
        return ext.isEmpty ? base + suffix : base + suffix + "." + ext
    }
}

public final class AsyncFileProviderMutationCoordinator: @unchecked Sendable {
    private let store: SQLiteStateStore?
    private let backend: any CloudreveAsyncBackend
    private let ownerID = UUID()

    public init(store: SQLiteStateStore?, backend: any CloudreveAsyncBackend) {
        self.store = store
        self.backend = backend
    }

    public func create(template: RemoteItem, contents: URL?, fields: NSFileProviderItemFields, options: NSFileProviderCreateItemOptions, context: FileProviderOperationContext) async throws -> RemoteItem {
        try context.cancellation.throwIfCancelled()
        guard let store else {
            return try await backend.create(CreateRequest(template: template, contents: contents, replayKey: template.itemIdentifier), context: context)
        }
        try store.assertProcessUsable()
        try validateSource(contents, item: template, store: store)
        try guardNotExcluded(item: template, kind: .localCreate, store: store)
        if template.kind == .symlink || template.kind == .unsupported {
            try store.createExclusionIntent(ExclusionIntent(
                itemIdentifier: template.itemIdentifier,
                systemItemIdentifier: template.itemIdentifier,
                ruleRevision: 1,
                kind: .unsupportedLocalType,
                sourceGeneration: 1,
                expectedVersion: template.version.content,
                pathHash: pathHash(template.uri),
                expiresAt: Date().addingTimeInterval(24 * 60 * 60)
            ))
            throw CoreFailure(code: .excludedFromSync, retryable: false)
        }
        let sourceFingerprint: (hash: Data, size: Int64)?
        if template.kind == .file, let contents {
            sourceFingerprint = try FileProviderSourceFingerprint.digest(url: contents)
        } else {
            sourceFingerprint = nil
        }
        let sourceKey = sourceFingerprint.map { "|\($0.hash.base64EncodedString())|\($0.size)" } ?? "|no-source"
        let replayKey = "create|\(template.itemIdentifier)|\(fields.rawValue)|\(options.rawValue)\(sourceKey)"
        // A different source for the same template means the file changed
        // before an earlier attempt finished; the newest source wins. Only a
        // create that already committed must not be repeated.
        try store.supersedeStaleOperations(itemIdentifier: template.itemIdentifier, exceptReplayKey: replayKey)
        if let existing = try store.latestOperation(itemIdentifier: template.itemIdentifier), existing.operation.replayKey != replayKey, existing.operation.state != "cancelled" {
            // The system replays a create whose completion never arrived with other options
            // (`mayAlreadyExist`) or fields; the same template and source already committed.
            if Self.isCommittedCreate(existing, templateIdentifier: template.itemIdentifier, sourceKey: sourceKey),
               let result = try committedResult(existing) {
                return result
            }
            throw operationMismatchFailure(existing.operation.state, stage: "create_source_replay_mismatch")
        }
        let operationID = stableOperationID(replayKey)
        let operation = try begin(operationID: operationID, replayKey: replayKey, kind: "create", itemIdentifier: template.itemIdentifier, expectedVersion: template.version.content, changedFields: String(fields.rawValue))
        if let result = try committedResult(operation) { return result }
        try ensureLease(operation)
        try store.insertItem(template)
        try store.setPending(template.itemIdentifier, templateIdentifier: template.itemIdentifier)
        let task = try store.createTransferTask(operationID: operationID, itemIdentifier: template.itemIdentifier, direction: "upload", totalBytes: sourceFingerprint?.size)
        do {
            let item = try await backend.create(CreateRequest(template: template, contents: contents, replayKey: replayKey), context: context)
            let committed = try commitRemoteResult(operationID: operationID, item: item, context: context)
            try store.updateTransferTask(taskID: task.taskID, state: "succeeded", bytes: task.totalBytes ?? 0, totalBytes: task.totalBytes)
            return committed
        } catch {
            try? store.updateTransferTask(taskID: task.taskID, state: "failed", bytes: 0, totalBytes: task.totalBytes, errorCode: (error as? CoreFailure)?.code.rawValue)
            persistUploadFailure(store: store, itemIdentifier: template.itemIdentifier, error: error)
            preserveUnknownOutcome(operationID: operationID, itemIdentifier: template.itemIdentifier, error: error)
            throw error
        }
    }

    public func modify(item: RemoteItem, baseVersion: Data, fields: NSFileProviderItemFields, contents: URL?, options: NSFileProviderModifyItemOptions, context: FileProviderOperationContext) async throws -> RemoteItem {
        try await modifyResolvingConflicts(item: item, baseVersion: baseVersion, fields: fields, contents: contents, options: options, context: context).item
    }

    /// Fields that are actually carried to Cloudreve. Everything else
    /// (xattrs, tags, dates, flags) stays local.
    public static let remoteModifyFields: NSFileProviderItemFields = [.contents, .filename, .parentItemIdentifier]

    public func modifyResolvingConflicts(item: RemoteItem, baseVersion: Data, fields: NSFileProviderItemFields, contents: URL?, options: NSFileProviderModifyItemOptions, context: FileProviderOperationContext) async throws -> ModifyOutcome {
        try context.cancellation.throwIfCancelled()
        guard let store else {
            return ModifyOutcome(item: try await backend.modify(ModifyRequest(item: item, expectedVersion: baseVersion, changedFields: fields, contents: contents, options: options, replayKey: item.itemIdentifier), context: context))
        }
        try store.assertProcessUsable()
        guard let stored = try store.item(identifier: item.itemIdentifier) else { throw CoreFailure(code: .notFound, retryable: false) }
        if fields.intersection(Self.remoteModifyFields).isEmpty {
            // Local-only metadata (last-used date, xattrs, tags, dates): no
            // remote round trip, no operation record, no permission check.
            if fields.contains(.lastUsedDate) {
                var state = try store.localItemState(identifier: stored.itemIdentifier)
                state.lastUsedAt = Date()
                try store.setLocalItemState(identifier: stored.itemIdentifier, state: state)
            }
            return ModifyOutcome(item: stored)
        }
        try validateSource(contents, item: item, store: store)
        try guardNotExcluded(item: item, kind: .localCreate, store: store)
        if fields.contains(.contents), let pending = try store.pendingConflictResolution(itemIdentifier: item.itemIdentifier) {
            return ModifyOutcome(item: try await resolvePendingConflict(item: item, baseVersion: baseVersion, contents: contents, options: options, pending: pending, context: context))
        }
        let fingerprint: (hash: Data, size: Int64)
        if let contents {
            fingerprint = try FileProviderSourceFingerprint.digest(url: contents)
        } else {
            fingerprint = (Data(), 0)
        }
        let replayKey = "modify|\(item.itemIdentifier)|\(baseVersion.base64EncodedString())|\(fields.rawValue)|\(fingerprint.hash.base64EncodedString())|\(fingerprint.size)"
        try store.supersedeStaleOperations(itemIdentifier: item.itemIdentifier, exceptReplayKey: replayKey)
        if let existing = try store.activeOperation(itemIdentifier: item.itemIdentifier), existing.operation.replayKey != replayKey {
            throw operationMismatchFailure(existing.operation.state, stage: "item_operation_in_flight")
        }
        let operationID = stableOperationID(replayKey)
        let previousParent = stored.parentIdentifier
        let operation = try begin(operationID: operationID, replayKey: replayKey, kind: "modify", itemIdentifier: item.itemIdentifier, expectedVersion: baseVersion, changedFields: String(fields.rawValue))
        if let result = try committedResult(operation) { return ModifyOutcome(item: result) }
        try ensureLease(operation)
        try store.setPending(item.itemIdentifier, templateIdentifier: nil)
        let task = try store.createTransferTask(operationID: operationID, itemIdentifier: item.itemIdentifier, direction: "upload", totalBytes: contents == nil ? nil : fingerprint.size)
        do {
            let updated: RemoteItem
            if fields.contains(.parentItemIdentifier) && item.parentIdentifier == NSFileProviderItemIdentifier.trashContainer.rawValue {
                updated = try await backend.trash(TrashRequest(item: item, expectedVersion: baseVersion, replayKey: replayKey), context: context)
            } else if item.trashed && fields.contains(.parentItemIdentifier) {
                updated = try await backend.restore(RestoreRequest(item: item, expectedVersion: baseVersion, replayKey: replayKey), context: context)
            } else {
                updated = try await backend.modify(ModifyRequest(item: item, expectedVersion: baseVersion, changedFields: fields, contents: contents, options: options, replayKey: replayKey), context: context)
            }
            let committed = try commitRemoteResult(operationID: operationID, item: updated, context: context, oldParentIdentifier: previousParent)
            try store.updateTransferTask(taskID: task.taskID, state: "succeeded", bytes: task.totalBytes ?? 0, totalBytes: task.totalBytes)
            return ModifyOutcome(item: committed)
        } catch {
            if let failure = error as? CoreFailure, failure.code == .versionConflict, fields.contains(.contents), let contents {
                // The server moved on while this edit was pending. Keep both:
                // the local bytes become a sibling conflict copy, and the
                // original item tracks the server version again.
                do {
                    let resolved = try await resolveWithConflictCopy(stored: stored, contents: contents, operationID: operationID, previousParent: previousParent, context: context)
                    try? store.updateTransferTask(taskID: task.taskID, state: "succeeded", bytes: task.totalBytes ?? 0, totalBytes: task.totalBytes)
                    return resolved
                } catch {
                    // Fall through: record the conflict for the Conflict
                    // Center so no local bytes are dropped.
                }
            }
            try? store.updateTransferTask(taskID: task.taskID, state: "failed", bytes: 0, totalBytes: task.totalBytes, errorCode: (error as? CoreFailure)?.code.rawValue)
            persistUploadFailure(store: store, itemIdentifier: item.itemIdentifier, error: error)
            if let failure = error as? CoreFailure, failure.code == .versionConflict {
                let conflict = ConflictProjection(
                    conflictID: stableOperationID("conflict|\(item.itemIdentifier)|\(baseVersion.base64EncodedString())"),
                    itemIdentifier: item.itemIdentifier,
                    kind: "version_conflict",
                    baseSummary: "version:\(short(baseVersion))",
                    remoteSummary: "remote_version_unknown",
                    localSummary: contents.map { _ in "bytes:\(fingerprint.size)" } ?? "metadata",
                    pendingItemIdentifier: item.itemIdentifier,
                    sourceGeneration: UInt64(max(1, try (store.systemSetState(setKind: "pending")?.currentGeneration ?? 0))),
                    // A 412 only proves that the supplied base is stale; it
                    // does not reveal the server's current version. Do not
                    // persist the local base as if it were the remote value,
                    // otherwise every later resolution would self-reject.
                    remoteVersion: nil,
                    localSourceKind: contents == nil ? "unavailable" : "system_pending",
                    expectedBaseVersion: baseVersion,
                    expectedSourceHash: contents == nil ? nil : fingerprint.hash,
                    expectedSourceSize: contents == nil ? nil : fingerprint.size
                )
                try? store.saveConflict(conflict)
            }
            preserveUnknownOutcome(operationID: operationID, itemIdentifier: item.itemIdentifier, error: error)
            throw error
        }
    }

    /// Resolves a persisted old-system conflict using a user-selected export.
    /// The selected URL is consumed during this callback only; no path or
    /// bookmark is persisted in the App Group store.
    public func resolveConflictFromSource(conflict: ConflictProjection, sourceURL: URL, options: NSFileProviderModifyItemOptions = [], context: FileProviderOperationContext) async throws -> RemoteItem {
        guard let store, let pending = try store.pendingConflictResolution(itemIdentifier: conflict.itemIdentifier), pending.conflictID == conflict.conflictID else {
            throw CoreFailure(code: .awaitingSourceReplay, retryable: false, userActionRequired: true)
        }
        guard let item = try await backend.item(identifier: conflict.itemIdentifier) else {
            throw CoreFailure(code: .notFound, retryable: false)
        }
        let baseVersion = conflict.expectedBaseVersion ?? item.version.content
        return try await resolvePendingConflict(item: item, baseVersion: baseVersion, contents: sourceURL, options: options, pending: pending, context: context)
    }

    public func delete(itemIdentifier: String, baseVersion: Data, recursive: Bool, context: FileProviderOperationContext) async throws {
        try context.cancellation.throwIfCancelled()
        guard let store else {
            try await backend.delete(DeleteRequest(itemIdentifier: itemIdentifier, expectedVersion: baseVersion, recursive: recursive, replayKey: itemIdentifier), context: context)
            return
        }
        try store.assertProcessUsable()
        guard let item = try store.item(identifier: itemIdentifier) else { return }
        let replayKey = "delete|\(itemIdentifier)|\(baseVersion.base64EncodedString())|\(recursive)"
        try store.supersedeStaleOperations(itemIdentifier: itemIdentifier, exceptReplayKey: replayKey)
        if let existing = try store.activeOperation(itemIdentifier: itemIdentifier), existing.operation.replayKey != replayKey {
            throw operationMismatchFailure(existing.operation.state, stage: "item_operation_in_flight")
        }
        let operationID = stableOperationID(replayKey)
        let operation = try begin(operationID: operationID, replayKey: replayKey, kind: "delete", itemIdentifier: itemIdentifier, expectedVersion: baseVersion, changedFields: recursive ? "recursive" : "single")
        if operation.operation.state == "committed" { return }
        if let failure = storedOperationTerminalFailure(operation.operation.state) { throw failure }
        let ruleRevision = max(1, (try store.isExcludedByCurrentRules(item: item)).revision)
        let consumedUnsupportedIntent = try store.consumeExclusionIntent(itemIdentifier: itemIdentifier, systemItemIdentifier: itemIdentifier, kind: .unsupportedLocalType, expectedVersion: baseVersion, pathHash: pathHash(item.uri), ruleRevision: 1, sourceGeneration: 1)
        let consumedLocalIntent = try store.consumeExclusionIntent(itemIdentifier: itemIdentifier, systemItemIdentifier: itemIdentifier, kind: .localCreate, expectedVersion: baseVersion, pathHash: pathHash(item.uri), ruleRevision: ruleRevision, sourceGeneration: 1)
        if consumedUnsupportedIntent || consumedLocalIntent {
            try store.commitOperation(operationID: operationID, state: "committed", itemIdentifier: itemIdentifier)
            return
        }
        if try store.hasExclusionCandidate(itemIdentifier: itemIdentifier, systemItemIdentifier: itemIdentifier) {
            throw CoreFailure(code: .excludedFromSync, retryable: false, userActionRequired: true)
        }
        try ensureLease(operation)
        let task = try store.createTransferTask(operationID: operationID, itemIdentifier: itemIdentifier, direction: "delete", totalBytes: nil)
        do {
            try await backend.delete(DeleteRequest(itemIdentifier: itemIdentifier, expectedVersion: baseVersion, recursive: recursive, replayKey: replayKey), context: context)
            var tombstone = item
            tombstone.tombstone = true
            _ = try commitRemoteResult(operationID: operationID, item: tombstone, context: context, oldParentIdentifier: item.parentIdentifier, recursive: recursive)
            try store.updateTransferTask(taskID: task.taskID, state: "succeeded", bytes: 0, totalBytes: nil)
        } catch {
            try? store.updateTransferTask(taskID: task.taskID, state: "failed", bytes: 0, totalBytes: nil, errorCode: (error as? CoreFailure)?.code.rawValue)
            preserveUnknownOutcome(operationID: operationID, itemIdentifier: itemIdentifier, error: error)
            throw error
        }
    }

    private func resolvePendingConflict(item: RemoteItem, baseVersion: Data, contents: URL?, options: NSFileProviderModifyItemOptions, pending: (conflictID: UUID, resolution: String, remoteVersion: Data?), context: FileProviderOperationContext) async throws -> RemoteItem {
        guard let store, let contents,
              let conflict = try store.pendingConflicts(limit: 500).first(where: { $0.conflictID == pending.conflictID }),
              let expectedHash = conflict.expectedSourceHash,
              let expectedSize = conflict.expectedSourceSize else {
            throw CoreFailure(code: .awaitingSourceReplay, retryable: false, userActionRequired: true)
        }
        guard try store.isOperationCapabilityVerified("fallback_conflict") else {
            throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["operation": "fallback_conflict"])
        }
        guard conflict.expectedBaseVersion == nil || conflict.expectedBaseVersion == baseVersion else {
            throw CoreFailure(code: .awaitingSourceReplay, retryable: false, userActionRequired: true)
        }
        let source: ConflictLocalSource
        if conflict.localSourceKind == "user_export" {
            source = .userExport(sourceGeneration: conflict.sourceGeneration, expectedHash: expectedHash, expectedSize: expectedSize)
        } else {
            source = .systemPending(itemIdentifier: item.itemIdentifier, sourceGeneration: conflict.sourceGeneration, expectedBaseVersion: conflict.expectedBaseVersion ?? baseVersion, expectedHash: expectedHash, expectedSize: expectedSize)
        }
        guard try ConflictSourceValidator.validate(source, url: contents, itemIdentifier: item.itemIdentifier, sourceGeneration: conflict.sourceGeneration) else {
            throw CoreFailure(code: .awaitingSourceReplay, retryable: false, userActionRequired: true)
        }
        switch try SpecialFilePolicy.decision(for: contents) {
        case .syncable:
            break
        case .excluded:
            throw CoreFailure(code: .excludedFromSync, retryable: false, userActionRequired: true)
        case .unsupportedMetadata:
            throw CoreFailure(code: .unsupportedMetadata, retryable: false, userActionRequired: true)
        }
        guard let current = try await backend.item(identifier: item.itemIdentifier) else {
            throw CoreFailure(code: .notFound, retryable: false)
        }
        if let remoteVersion = pending.remoteVersion, remoteVersion != current.version.content {
            throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true)
        }
        let replayKey = "conflict-\(pending.resolution)|\(pending.conflictID.uuidString)"
        let operationID = stableOperationID(replayKey)
        let operation = try begin(operationID: operationID, replayKey: replayKey, kind: pending.resolution, itemIdentifier: item.itemIdentifier, expectedVersion: baseVersion, changedFields: "contents")
        if let result = try committedResult(operation) {
            try store.completeConflictResolution(
                itemIdentifier: item.itemIdentifier,
                conflictID: pending.conflictID,
                resolution: pending.resolution.replacingOccurrences(of: "_pending", with: "")
            )
            return result
        }
        try ensureLease(operation)
        do {
            let result: RemoteItem
            if pending.resolution == "overwrite_remote_pending" {
                result = try await backend.modify(ModifyRequest(item: current, expectedVersion: current.version.content, changedFields: [.contents], contents: contents, options: options, replayKey: replayKey), context: context)
            } else if pending.resolution == "keep_both_pending" {
                let copy = RemoteItem(itemIdentifier: CloudreveIdentifier.item(forTemplate: replayKey), parentIdentifier: current.parentIdentifier, name: "\(current.name) (NimbusSync conflict)", uri: current.uri, kind: current.kind, contentType: current.contentType, size: expectedSize, version: ItemVersion(content: Data(), metadata: Data()), canRead: true, canWrite: current.canWrite, canAddChildren: current.canAddChildren, canTrash: current.canTrash, canDelete: current.canDelete)
                result = try await backend.create(CreateRequest(template: copy, contents: contents, replayKey: replayKey), context: context)
            } else {
                throw CoreFailure(code: .unsupportedMetadata, retryable: false, userActionRequired: true)
            }
            let committed = try commitRemoteResult(operationID: operationID, item: result, context: context, oldParentIdentifier: current.parentIdentifier)
            try store.completeConflictResolution(itemIdentifier: item.itemIdentifier, conflictID: pending.conflictID, resolution: pending.resolution.replacingOccurrences(of: "_pending", with: ""))
            return committed
        } catch {
            preserveUnknownOutcome(operationID: operationID, itemIdentifier: item.itemIdentifier, error: error)
            throw error
        }
    }

    private func resolveWithConflictCopy(stored: RemoteItem, contents: URL, operationID: UUID, previousParent: String?, context: FileProviderOperationContext) async throws -> ModifyOutcome {
        guard let store else { throw CoreFailure(code: .database, retryable: false) }
        guard let remote = try await backend.refreshItem(identifier: stored.itemIdentifier, context: context), !remote.tombstone, !remote.trashed else {
            throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true)
        }
        let copyName = ConflictCopyNaming.name(for: stored.name)
        let template = RemoteItem(
            parentIdentifier: remote.parentIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue,
            name: copyName,
            uri: remote.uri,
            kind: .file,
            contentType: CloudreveItemMapper.contentType(kind: .file, name: copyName),
            size: PartialDownloadStore.size(of: contents),
            version: ItemVersion(content: Data(), metadata: Data()),
            canRead: true,
            canWrite: true,
            canTrash: true
        )
        let copy = try await backend.create(CreateRequest(template: template, contents: contents, replayKey: "conflict-copy|\(operationID.uuidString)"), context: context)
        _ = try store.commitProviderChange(item: copy, oldParentIdentifier: nil, newParentIdentifier: copy.parentIdentifier, kind: "created", origin: "conflict_copy")
        let committed = try commitRemoteResult(operationID: operationID, item: remote, context: context, oldParentIdentifier: previousParent)
        return ModifyOutcome(item: committed, shouldFetchContent: true, conflictCopy: copy)
    }

    private func begin(operationID: UUID, replayKey: String, kind: String, itemIdentifier: String, expectedVersion: Data? = nil, changedFields: String? = nil) throws -> StoredOperation {
        guard let store else { throw CoreFailure(code: .database, retryable: false) }
        _ = try store.upsertOperation(PendingOperation(operationID: operationID, replayKey: replayKey, kind: kind, itemIdentifier: itemIdentifier, sourceGeneration: 1, expectedVersion: expectedVersion, changedFields: changedFields))
        // The system replaying the identical callback is the retry signal.
        // Transient failures must not turn into a permanent wedge.
        try store.reopenOperation(replayKey: replayKey)
        guard let operation = try store.operation(replayKey: replayKey) else { throw CoreFailure(code: .database, retryable: false) }
        return operation
    }

    /// Matches a committed create replay key `create|<template>|<fields>|<options><sourceKey>` for
    /// the same template and source, whatever fields and options the earlier attempt carried.
    static func isCommittedCreate(_ operation: StoredOperation, templateIdentifier: String, sourceKey: String) -> Bool {
        guard operation.operation.state == "committed", operation.operation.kind == "create" else { return false }
        let key = operation.operation.replayKey
        let prefix = "create|\(templateIdentifier)|"
        guard key.hasPrefix(prefix), key.hasSuffix(sourceKey), key.count >= prefix.count + sourceKey.count else { return false }
        let middle = key.dropFirst(prefix.count).dropLast(sourceKey.count).split(separator: "|", omittingEmptySubsequences: false)
        return middle.count == 2 && middle.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private func committedResult(_ operation: StoredOperation) throws -> RemoteItem? {
        if let failure = storedOperationTerminalFailure(operation.operation.state) { throw failure }
        guard operation.operation.state == "committed" else { return nil }
        guard let outcome = operation.outcome, let data = outcome.data(using: .utf8) else { throw CoreFailure(code: .unknownOutcome, retryable: false, userActionRequired: true) }
        return try JSONDecoder().decode(RemoteItem.self, from: data)
    }

    private func commitRemoteResult(operationID: UUID, item: RemoteItem, context: FileProviderOperationContext, oldParentIdentifier: String? = nil, recursive: Bool = false) throws -> RemoteItem {
        guard let store else { throw CoreFailure(code: .database, retryable: false) }
        let outcome = String(data: try JSONEncoder().encode(item), encoding: .utf8)
        let kind = item.tombstone ? "deleted" : "operation_result"
        if context.cancellation.isCancelled || Task.isCancelled {
            try store.commitOperationWithItemAndChange(operationID: operationID, state: "unknown_outcome", item: item, oldParentIdentifier: oldParentIdentifier, newParentIdentifier: item.tombstone ? nil : item.parentIdentifier, kind: kind, origin: "local_mutation", outcome: outcome, recursive: recursive)
            throw CoreFailure(code: .unknownOutcome, retryable: false, userActionRequired: true)
        }
        try store.commitOperationWithItemAndChange(operationID: operationID, state: "committed", item: item, oldParentIdentifier: oldParentIdentifier, newParentIdentifier: item.tombstone ? nil : item.parentIdentifier, kind: kind, origin: "local_mutation", outcome: outcome, recursive: recursive)
        return item
    }

    private func ensureLease(_ operation: StoredOperation) throws {
        guard let store else { return }
        if operation.operation.state == "committed" { return }
        if try store.cancelRequested(operationID: operation.operation.operationID) {
            try store.commitOperation(operationID: operation.operation.operationID, state: "cancelled", itemIdentifier: operation.operation.itemIdentifier)
            throw CoreFailure(code: .cancelled, retryable: false)
        }
        guard try store.acquireOperationLease(operationID: operation.operation.operationID, owner: ownerID) else {
            throw CoreFailure(code: .unknownOutcome, retryable: true)
        }
    }

    private func preserveUnknownOutcome(operationID: UUID, itemIdentifier: String, error: Error) {
        guard let store else { return }
        let state: String
        if let failure = error as? CoreFailure {
            switch failure.code {
            case .versionConflict: state = "conflict"
            case .authentication: state = "auth_expired"
            case .awaitingSourceReplay: state = "awaiting_source_replay"
            case .cancelled: state = "cancelled"
            default: state = failure.retryable ? "retry_pending" : "unknown_outcome"
            }
        } else {
            state = "unknown_outcome"
        }
        try? store.commitOperation(operationID: operationID, state: state, itemIdentifier: itemIdentifier)
    }

    private func persistUploadFailure(store: SQLiteStateStore, itemIdentifier: String, error: Error) {
        let failure = error as? CoreFailure
        let state: LocalTransferState = failure?.code == .awaitingSourceReplay ? .awaitingSourceReplay : .failed
        let errorCode = failure?.code.rawValue ?? "upload_failed"
        try? store.setTransferState(identifier: itemIdentifier, direction: "upload", state: state, error: errorCode)
    }

    private func pathHash(_ uri: String) -> Data {
        Data(SHA256.hash(data: Data(uri.utf8)))
    }

    private func operationMismatchFailure(_ state: String, stage: String) -> CoreFailure {
        if state == "awaiting_source_replay" {
            return CoreFailure(code: .awaitingSourceReplay, retryable: false, userActionRequired: true, redactedContext: ["stage": stage])
        }
        if let failure = storedOperationTerminalFailure(state) { return failure }
        return CoreFailure(code: .unknownOutcome, retryable: true, userActionRequired: true, redactedContext: ["stage": stage])
    }

    private func short(_ value: Data) -> String { value.prefix(8).map { String(format: "%02x", $0) }.joined() }

    private func validateSource(_ contents: URL?, item: RemoteItem, store: SQLiteStateStore) throws {
        guard let contents else { return }
        switch try SpecialFilePolicy.decision(for: contents) {
        case .syncable:
            return
        case .excluded:
            try store.createExclusionIntent(ExclusionIntent(itemIdentifier: item.itemIdentifier, systemItemIdentifier: item.itemIdentifier, ruleRevision: 1, kind: .unsupportedLocalType, sourceGeneration: 1, expectedVersion: item.version.content, pathHash: Data(SHA256.hash(data: Data(item.uri.utf8)))))
            throw CoreFailure(code: .excludedFromSync, retryable: false)
        case .unsupportedMetadata:
            try store.createExclusionIntent(ExclusionIntent(itemIdentifier: item.itemIdentifier, systemItemIdentifier: item.itemIdentifier, ruleRevision: 1, kind: .unsupportedLocalType, sourceGeneration: 1, expectedVersion: item.version.content, pathHash: Data(SHA256.hash(data: Data(item.uri.utf8)))))
            throw CoreFailure(code: .unsupportedMetadata, retryable: false, userActionRequired: true)
        }
    }

    private func guardNotExcluded(item: RemoteItem, kind: ExclusionIntent.Kind, store: SQLiteStateStore) throws {
        let decision = try store.isExcludedByCurrentRules(item: item)
        guard !decision.excluded else {
            try store.createExclusionIntent(ExclusionIntent(itemIdentifier: item.itemIdentifier, systemItemIdentifier: item.itemIdentifier, ruleRevision: max(1, decision.revision), kind: kind, sourceGeneration: 1, expectedVersion: item.version.content, pathHash: pathHash(item.uri)))
            throw CoreFailure(code: .excludedFromSync, retryable: false)
        }
    }
}

private func stableOperationID(_ value: String) -> UUID {
    let digest = SHA256.hash(data: Data(value.utf8))
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
}
