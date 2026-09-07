import Foundation
import FileProvider
import CSQLite
import CloudreveDomainKit

public enum KeepDownloadedPolicy: String, Codable, Sendable {
    case inherit
    case keepDownloaded = "keep_downloaded"
    case automatic
}

public enum LocalTransferState: String, Codable, Sendable {
    case none
    case queued
    case running
    case retryWait = "retry_wait"
    case awaitingSourceReplay = "awaiting_source_replay"
    case completed
    case failed
}

public struct ItemLocalState: Codable, Equatable, Sendable {
    public var materialized: Bool
    public var visited: Bool
    public var keepPolicy: KeepDownloadedPolicy
    public var uploadState: LocalTransferState
    public var downloadState: LocalTransferState
    public var uploadError: String?
    public var downloadError: String?
    public var systemVisible: Bool
    public var viewExcluded: Bool
    public var lastUsedAt: Date?

    public init(
        materialized: Bool = false,
        visited: Bool = false,
        keepPolicy: KeepDownloadedPolicy = .inherit,
        uploadState: LocalTransferState = .none,
        downloadState: LocalTransferState = .none,
        uploadError: String? = nil,
        downloadError: String? = nil,
        systemVisible: Bool = false,
        viewExcluded: Bool = false,
        lastUsedAt: Date? = nil
    ) {
        self.materialized = materialized
        self.visited = visited
        self.keepPolicy = keepPolicy
        self.uploadState = uploadState
        self.downloadState = downloadState
        self.uploadError = uploadError
        self.downloadError = downloadError
        self.systemVisible = systemVisible
        self.viewExcluded = viewExcluded
        self.lastUsedAt = lastUsedAt
    }
}

public struct ItemProjection: Codable, Equatable, Sendable {
    public let item: RemoteItem
    public let localState: ItemLocalState
    public let effectiveKeepPolicy: KeepDownloadedPolicy
    public let metadataMoveAllowed: Bool
    public let operationState: String?
    public let childItemCount: Int64?
    public let hasConflict: Bool

    public init(item: RemoteItem, localState: ItemLocalState, effectiveKeepPolicy: KeepDownloadedPolicy? = nil, metadataMoveAllowed: Bool? = nil, operationState: String? = nil, childItemCount: Int64? = nil, hasConflict: Bool = false) {
        self.item = item
        self.localState = localState
        self.effectiveKeepPolicy = effectiveKeepPolicy ?? localState.keepPolicy
        self.metadataMoveAllowed = metadataMoveAllowed ?? item.canWrite
        self.operationState = operationState
        self.childItemCount = childItemCount
        self.hasConflict = hasConflict
    }

    public var isUploaded: Bool {
        guard item.remoteID != nil, !item.tombstone else { return false }
        guard localState.uploadError == nil, [.none, .completed].contains(localState.uploadState) else { return false }
        return operationState.map { $0 == "committed" || $0 == "resolved" } ?? true
    }

    public var isPending: Bool {
        operationState.map { !["committed", "cancelled", "permanently_failed", "resolved"].contains($0) } ?? (localState.uploadState != .none || localState.downloadState != .none)
    }
}

public struct DirectorySnapshotDescriptor: Equatable, Sendable {
    public let snapshotID: String
    public let domainIdentifier: String
    public let parentIdentifier: String
    public let generation: UInt64
    public let expiresAt: Date
    public let state: String
    public let nextCursor: Data?

    public init(snapshotID: String, domainIdentifier: String, parentIdentifier: String, generation: UInt64, expiresAt: Date, state: String, nextCursor: Data? = nil) {
        self.snapshotID = snapshotID
        self.domainIdentifier = domainIdentifier
        self.parentIdentifier = parentIdentifier
        self.generation = generation
        self.expiresAt = expiresAt
        self.state = state
        self.nextCursor = nextCursor
    }
}

public struct SystemSetClaim: Equatable, Sendable {
    public let setKind: String
    public let generation: Int64
    public let ownerID: UUID
    public let domainVersion: Data?
    public init(setKind: String, generation: Int64, ownerID: UUID = UUID(), domainVersion: Data?) {
        self.setKind = setKind
        self.generation = generation
        self.ownerID = ownerID
        self.domainVersion = domainVersion
    }
}

public struct SystemSetState: Equatable, Sendable {
    public let setKind: String
    public let currentGeneration: Int64
    public let activeGeneration: Int64?
    public let refreshRequired: Bool
    public let scanState: String
    public let maximumSizeReached: Bool
    public let cursor: Data?
    public let lastCompletedAt: Date?

    public init(setKind: String, currentGeneration: Int64, activeGeneration: Int64?, refreshRequired: Bool, scanState: String, maximumSizeReached: Bool, cursor: Data?, lastCompletedAt: Date?) {
        self.setKind = setKind
        self.currentGeneration = currentGeneration
        self.activeGeneration = activeGeneration
        self.refreshRequired = refreshRequired
        self.scanState = scanState
        self.maximumSizeReached = maximumSizeReached
        self.cursor = cursor
        self.lastCompletedAt = lastCompletedAt
    }
}

public struct ProjectionRefreshJob: Equatable, Sendable {
    public let jobID: UUID
    public let domainIdentifier: String
    public let targetRevision: UInt64
    public let scope: String
    public let cursor: String?
    public let state: String
    public let attempt: Int
    public let lastError: String?
    public let fallbackEnabled: Bool

    public init(jobID: UUID, domainIdentifier: String, targetRevision: UInt64, scope: String, cursor: String?, state: String, attempt: Int, lastError: String?, fallbackEnabled: Bool) {
        self.jobID = jobID
        self.domainIdentifier = domainIdentifier
        self.targetRevision = targetRevision
        self.scope = scope
        self.cursor = cursor
        self.state = state
        self.attempt = attempt
        self.lastError = lastError
        self.fallbackEnabled = fallbackEnabled
    }
}

public struct TransferTaskSnapshot: Equatable, Sendable {
    public let taskID: UUID
    public let operationID: UUID?
    public let itemIdentifier: String?
    public let direction: String
    public let state: String
    public let bytes: Int64
    public let totalBytes: Int64?
    public let errorCode: String?
    public let updatedAt: Date

    public init(taskID: UUID, operationID: UUID?, itemIdentifier: String?, direction: String, state: String, bytes: Int64, totalBytes: Int64?, errorCode: String?, updatedAt: Date = Date()) {
        self.taskID = taskID
        self.operationID = operationID
        self.itemIdentifier = itemIdentifier
        self.direction = direction
        self.state = state
        self.bytes = bytes
        self.totalBytes = totalBytes
        self.errorCode = errorCode
        self.updatedAt = updatedAt
    }
}

public struct ConflictSourceRecord: Equatable, Sendable {
    public let kind: String
    public let sourceGeneration: UInt64
    public let expectedBaseVersion: Data?
    public let expectedHash: Data?
    public let expectedSize: Int64?

    public init(kind: String, sourceGeneration: UInt64, expectedBaseVersion: Data?, expectedHash: Data?, expectedSize: Int64?) {
        self.kind = kind
        self.sourceGeneration = sourceGeneration
        self.expectedBaseVersion = expectedBaseVersion
        self.expectedHash = expectedHash
        self.expectedSize = expectedSize
    }
}

public struct ExclusionRuleSnapshot: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let rules: [String]
    public let caseSensitive: Bool

    public init(revision: UInt64, rules: [String], caseSensitive: Bool = false) {
        self.revision = revision
        self.rules = rules
        self.caseSensitive = caseSensitive
    }

    public func matches(relativePath: String, isRoot: Bool = false) -> Bool {
        ExclusionMatcher.matches(relativePath: relativePath, rules: rules, caseSensitive: caseSensitive, isRoot: isRoot)
    }
}

public enum SQLiteSchemaManifest {
    public static let version = SQLiteStateStore.schemaVersion
    public static let tables: [String] = [
        "auth_lease", "change_journal", "conflicts", "directory_snapshot_generations",
        "directory_snapshot_heads", "directory_snapshot_items", "directory_snapshots",
        "domain_actions", "domains", "exclusion_intents", "item_local_state", "items",
        "materialized_containers", "operations", "pending_creations", "pending_items",
        "preferences", "process_heartbeats", "projection_refresh_jobs", "reconcile_runs",
        "schema_meta", "signal_outbox", "sync_state", "system_pending_observations", "system_set_state",
        "tasks", "upload_parts", "upload_sessions", "visited_containers"
    ]
}

public struct SchemaManifestSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let tables: [String]
    public let columns: [String: [String]]
    public let indexes: [String]

    public init(version: Int, tables: [String], columns: [String: [String]], indexes: [String]) {
        self.version = version
        self.tables = tables
        self.columns = columns
        self.indexes = indexes
    }
}

public extension SQLiteStateStore {
    func applyExclusionRules(_ snapshot: ExclusionRuleSnapshot, domainIdentifier: String, rootURI: String) throws -> [JournalChange] {
        let items = try allItems()
        let encodedRules = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8) ?? ""
        return try withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("INSERT OR REPLACE INTO preferences (key, value, updated_at) VALUES ('exclusion.rules.\(sql(domainIdentifier))', '\(sql(encodedRules))', unixepoch())")
                // Snapshot membership was materialized under the previous
                // view rule. Invalidate only item-page cache so an old page
                // cannot re-expose an excluded item; the immutable journal
                // below still carries the incremental view change.
                try execute("DELETE FROM directory_snapshot_heads")
                try execute("DELETE FROM directory_snapshot_generations")
                try execute("DELETE FROM directory_snapshots")
                var changes: [JournalChange] = []
                for item in items {
                    let relative = CloudreveRemoteURI.relativePath(item.uri, root: rootURI) ?? item.name
                    let excluded = snapshot.matches(relativePath: relative, isRoot: item.itemIdentifier == NSFileProviderItemIdentifier.rootContainer.rawValue)
                    var state = try localStateUnlocked(identifier: item.itemIdentifier)
                    guard state.viewExcluded != excluded else { continue }
                    state.viewExcluded = excluded
                    try upsertLocalStateUnlocked(identifier: item.itemIdentifier, state: state)
                    let payload = try encodeJournalPayload(item)
                    changes.append(try appendProviderChangeUnlocked(itemIdentifier: item.itemIdentifier, oldParentIdentifier: item.parentIdentifier, newParentIdentifier: item.parentIdentifier, kind: excluded ? "view_removed" : "view_added", version: item.version.content, origin: "exclusion", itemPayload: payload, itemVersion: item.version))
                }
                try execute("COMMIT")
                return changes
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func commitProviderViewChange(item: RemoteItem, oldParentIdentifier: String?, newParentIdentifier: String?, excluded: Bool, origin: String) throws -> JournalChange {
        try withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                try invalidateDirectorySnapshotsUnlocked()
                try insertItemUnlocked(item)
                var state = try localStateUnlocked(identifier: item.itemIdentifier)
                state.viewExcluded = excluded
                try upsertLocalStateUnlocked(identifier: item.itemIdentifier, state: state)
                let payload = try encodeJournalPayload(item)
                let change = try appendProviderChangeUnlocked(itemIdentifier: item.itemIdentifier, oldParentIdentifier: oldParentIdentifier, newParentIdentifier: newParentIdentifier, kind: excluded ? "view_removed" : "view_added", version: item.version.content, origin: origin, itemPayload: payload, itemVersion: item.version)
                try execute("COMMIT")
                return change
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func exclusionRuleSnapshot(domainIdentifier: String) throws -> ExclusionRuleSnapshot? {
        try withLock {
            guard let encoded = try scalar("SELECT value FROM preferences WHERE key = 'exclusion.rules.\(sql(domainIdentifier))' LIMIT 1"), let data = encoded.data(using: .utf8) else { return nil }
            return try JSONDecoder().decode(ExclusionRuleSnapshot.self, from: data)
        }
    }

    func isExcludedByCurrentRules(item: RemoteItem, domainIdentifier: String? = nil) throws -> (excluded: Bool, revision: UInt64) {
        try withLock {
            let resolvedDomain: String
            if let domainIdentifier {
                resolvedDomain = domainIdentifier
            } else {
                resolvedDomain = try scalar("SELECT domain_id FROM domains ORDER BY domain_id LIMIT 1") ?? ""
            }
            guard let rules = try exclusionRulesUnlocked(domainIdentifier: resolvedDomain) else { return (false, 0) }
            let rootURI = try scalar("SELECT root_uri FROM domains WHERE domain_id = '\(sql(resolvedDomain))' LIMIT 1") ?? "/"
            let relative = CloudreveRemoteURI.relativePath(item.uri, root: rootURI) ?? item.name
            return (rules.matches(relativePath: relative, isRoot: item.itemIdentifier == NSFileProviderItemIdentifier.rootContainer.rawValue), rules.revision)
        }
    }

    func schemaManifest() throws -> SchemaManifestSnapshot {
        try withLock {
            let tablesStatement = try prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            var tables: [String] = []
            while sqlite3_step(tablesStatement) == SQLITE_ROW {
                if let name = columnString(tablesStatement, 0) { tables.append(name) }
            }
            sqlite3_finalize(tablesStatement)
            var columns: [String: [String]] = [:]
            for table in tables {
                let statement = try prepare("PRAGMA table_info('\(sql(table))')")
                var tableColumns: [String] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let name = columnString(statement, 1) { tableColumns.append(name) }
                }
                sqlite3_finalize(statement)
                columns[table] = tableColumns
            }
            let indexesStatement = try prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            var indexes: [String] = []
            while sqlite3_step(indexesStatement) == SQLITE_ROW {
                if let name = columnString(indexesStatement, 0) { indexes.append(name) }
            }
            sqlite3_finalize(indexesStatement)
            return SchemaManifestSnapshot(version: SQLiteStateStore.schemaVersion, tables: tables, columns: columns, indexes: indexes)
        }
    }

    func setConflictSource(conflictID: UUID, source: ConflictSourceRecord) throws {
        try withLock {
            try execute("UPDATE conflicts SET local_source_kind = '\(sql(source.kind))', expected_base_version = \(source.expectedBaseVersion.map { "X'\($0.hexString)'" } ?? "NULL"), expected_source_hash = \(source.expectedHash.map { "X'\($0.hexString)'" } ?? "NULL"), expected_source_size = \(source.expectedSize.map(String.init) ?? "NULL"), resolution_state = 'source_available', updated_at = unixepoch() WHERE conflict_id = '\(conflictID.uuidString)'")
        }
    }

    func markConflictSourceReplayRequested(conflictID: UUID) throws {
        try withLock { try execute("UPDATE conflicts SET resolution_state = 'replay_requested', updated_at = unixepoch() WHERE conflict_id = '\(conflictID.uuidString)' AND state = 'pending'") }
    }

    func conflictSource(conflictID: UUID) throws -> ConflictSourceRecord? {
        try withLock {
            let statement = try prepare("SELECT local_source_kind, source_generation, expected_base_version, expected_source_hash, expected_source_size FROM conflicts WHERE conflict_id = '\(conflictID.uuidString)' LIMIT 1")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let kind = columnString(statement, 0) else { return nil }
            return ConflictSourceRecord(kind: kind, sourceGeneration: UInt64(max(0, sqlite3_column_int64(statement, 1))), expectedBaseVersion: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : columnBlob(statement, 2), expectedHash: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : columnBlob(statement, 3), expectedSize: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 4))
        }
    }

    func projectionRevisionState() throws -> (current: UInt64, lastApplied: UInt64) {
        try withLock {
            let statement = try prepare("SELECT projection_schema_revision, last_applied_projection_schema_revision FROM sync_state WHERE singleton = 1")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreBridgeError.unknownDomain }
            return (UInt64(max(0, sqlite3_column_int64(statement, 0))), UInt64(max(0, sqlite3_column_int64(statement, 1))))
        }
    }

    func isOperationCapabilityVerified(_ operation: String) throws -> Bool {
        try withLock {
            guard let encoded = try scalar("SELECT capability_snapshot FROM domains ORDER BY domain_id LIMIT 1"),
                  let data = encoded.data(using: .utf8),
                  let snapshot = try? JSONDecoder().decode(CapabilitySnapshot.self, from: data) else {
                return false
            }
            return snapshot.operationVerified(operation)
        }
    }

    func activeProjectionRefreshJob(domainIdentifier: String) throws -> ProjectionRefreshJob? {
        try withLock {
            // Failed refreshes retain their cursor and are resumable. Treat
            // them as active work on the next extension launch rather than
            // creating a new job that silently starts from the beginning.
            let statement = try prepare("SELECT job_id, domain_id, target_revision, scope, cursor, state, attempt, last_error, feature_fallback_enabled FROM projection_refresh_jobs WHERE domain_id = '\(sql(domainIdentifier))' AND state IN ('active', 'failed') ORDER BY updated_at ASC LIMIT 1")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let id = UUID(uuidString: columnString(statement, 0) ?? "") else { return nil }
            return ProjectionRefreshJob(jobID: id, domainIdentifier: columnString(statement, 1) ?? domainIdentifier, targetRevision: UInt64(max(0, sqlite3_column_int64(statement, 2))), scope: columnString(statement, 3) ?? "working_set", cursor: columnString(statement, 4), state: columnString(statement, 5) ?? "active", attempt: Int(sqlite3_column_int(statement, 6)), lastError: columnString(statement, 7), fallbackEnabled: sqlite3_column_int(statement, 8) != 0)
        }
    }

    func createTransferTask(taskID: UUID = UUID(), operationID: UUID?, itemIdentifier: String?, direction: String, totalBytes: Int64?) throws -> TransferTaskSnapshot {
        let snapshot = try withLock {
            try execute("INSERT OR REPLACE INTO tasks (task_id, operation_id, item_identifier, direction, state, bytes, total_bytes, error_code, updated_at) VALUES ('\(taskID.uuidString)', \(operationID.map { "'\($0.uuidString)'" } ?? "NULL"), \(nullable(itemIdentifier)), '\(sql(direction))', 'running', 0, \(totalBytes.map(String.init) ?? "NULL"), NULL, unixepoch())")
            return TransferTaskSnapshot(taskID: taskID, operationID: operationID, itemIdentifier: itemIdentifier, direction: direction, state: "running", bytes: 0, totalBytes: totalBytes, errorCode: nil, updatedAt: Date())
        }
        try? compactTransferState()
        return snapshot
    }

    func updateTransferTask(taskID: UUID, state: String, bytes: Int64, totalBytes: Int64?, errorCode: String? = nil) throws {
        try withLock {
            try execute("UPDATE tasks SET state = '\(sql(state))', bytes = \(max(0, bytes)), total_bytes = \(totalBytes.map(String.init) ?? "NULL"), error_code = \(nullable(errorCode)), updated_at = unixepoch() WHERE task_id = '\(taskID.uuidString)'")
        }
    }

    /// Reclaims only transfer records whose durable operation outcome no
    /// longer needs them. Unknown, awaiting-source-replay, queued and running
    /// records are deliberately retained for recovery.
    func compactTransferState(now: Date = Date(), terminalTaskAge: TimeInterval = 7 * 24 * 60 * 60) throws {
        try withLock {
            try execute("DELETE FROM upload_parts WHERE operation_id IN (SELECT s.operation_id FROM upload_sessions s LEFT JOIN operations o ON o.operation_id = s.operation_id WHERE s.secret_ref IS NULL AND (s.state = 'abandoned' OR (s.state = 'completed' AND (o.state IN ('committed', 'resolved', 'cancelled', 'permanently_failed') OR o.operation_id IS NULL))))")
            try execute("DELETE FROM upload_sessions WHERE secret_ref IS NULL AND (state = 'abandoned' OR (state = 'completed' AND operation_id IN (SELECT operation_id FROM operations WHERE state IN ('committed', 'resolved', 'cancelled', 'permanently_failed'))))")
            let cutoff = Int64(now.timeIntervalSince1970 - max(0, terminalTaskAge))
            try execute("DELETE FROM tasks WHERE state IN ('succeeded', 'failed', 'cancelled') AND updated_at < \(cutoff)")
            try execute("DELETE FROM upload_parts WHERE NOT EXISTS (SELECT 1 FROM upload_sessions s WHERE s.operation_id = upload_parts.operation_id)")
        }
    }

    func transferTask(taskID: UUID) throws -> TransferTaskSnapshot? {
        try withLock {
            let statement = try prepare("SELECT task_id, operation_id, item_identifier, direction, state, bytes, total_bytes, error_code, updated_at FROM tasks WHERE task_id = '\(taskID.uuidString)' LIMIT 1")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let id = UUID(uuidString: columnString(statement, 0) ?? "") else { return nil }
            return TransferTaskSnapshot(taskID: id, operationID: columnString(statement, 1).flatMap(UUID.init(uuidString:)), itemIdentifier: columnString(statement, 2), direction: columnString(statement, 3) ?? "other", state: columnString(statement, 4) ?? "unknown", bytes: sqlite3_column_int64(statement, 5), totalBytes: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 6), errorCode: columnString(statement, 7), updatedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 8))))
        }
    }

    func latestTransferTask(operationID: UUID) throws -> TransferTaskSnapshot? {
        try withLock {
            let statement = try prepare("SELECT task_id, operation_id, item_identifier, direction, state, bytes, total_bytes, error_code, updated_at FROM tasks WHERE operation_id = '\(operationID.uuidString)' ORDER BY updated_at DESC, rowid DESC LIMIT 1")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let id = UUID(uuidString: columnString(statement, 0) ?? "") else { return nil }
            return TransferTaskSnapshot(taskID: id, operationID: columnString(statement, 1).flatMap(UUID.init(uuidString:)), itemIdentifier: columnString(statement, 2), direction: columnString(statement, 3) ?? "other", state: columnString(statement, 4) ?? "unknown", bytes: sqlite3_column_int64(statement, 5), totalBytes: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 6), errorCode: columnString(statement, 7), updatedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 8))))
        }
    }

    func transferTasks(limit: Int = 100) throws -> [TransferTaskSnapshot] {
        try withLock {
            let statement = try prepare("SELECT task_id, operation_id, item_identifier, direction, state, bytes, total_bytes, error_code, updated_at FROM tasks ORDER BY updated_at DESC, rowid DESC LIMIT \(max(1, min(limit, 500)))")
            defer { sqlite3_finalize(statement) }
            var result: [TransferTaskSnapshot] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = UUID(uuidString: columnString(statement, 0) ?? "") else { continue }
                result.append(TransferTaskSnapshot(taskID: id, operationID: columnString(statement, 1).flatMap(UUID.init(uuidString:)), itemIdentifier: columnString(statement, 2), direction: columnString(statement, 3) ?? "other", state: columnString(statement, 4) ?? "unknown", bytes: sqlite3_column_int64(statement, 5), totalBytes: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 6), errorCode: columnString(statement, 7), updatedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 8)))))
            }
            return result
        }
    }

    func setTransferState(identifier: String, direction: String, state: LocalTransferState, error: String? = nil) throws {
        try withLock {
            var local = try localStateUnlocked(identifier: identifier)
            if direction == "download" {
                local.downloadState = state
                local.downloadError = error
            } else {
                local.uploadState = state
                local.uploadError = error
            }
            try upsertLocalStateUnlocked(identifier: identifier, state: local)
        }
    }

    func commitOperationWithItemAndChange(operationID: UUID, state: String, item: RemoteItem, oldParentIdentifier: String?, newParentIdentifier: String?, kind: String, origin: String, outcome: String? = nil, recursive: Bool = false) throws {
        try withLock {
            let encodedOutcome = outcome.map { Data($0.utf8).base64EncodedString() }
            try execute("BEGIN IMMEDIATE")
            do {
                let previous = try itemUnlockedForProjection(identifier: item.itemIdentifier)
                if recursive, item.tombstone, item.kind == .folder {
                    let refreshed = try tombstoneDescendantsUnlocked(rootIdentifier: item.itemIdentifier, oldURI: previous?.uri ?? item.uri)
                    if refreshed >= 100_000 {
                        try execute("UPDATE sync_state SET reconcile_status = 'required:recursive_delete' WHERE singleton = 1")
                    }
                }
                try insertItemUnlocked(item)
                let payload = try encodeJournalPayload(item)
                _ = try appendProviderChangeUnlocked(itemIdentifier: item.itemIdentifier, oldParentIdentifier: oldParentIdentifier, newParentIdentifier: newParentIdentifier, kind: kind, version: item.version.content, origin: origin, itemPayload: payload, itemVersion: item.version)
                if item.kind == .folder, let previous, previous.uri != item.uri {
                    let refreshed = try refreshDescendantURIsUnlocked(rootIdentifier: item.itemIdentifier, oldURI: previous.uri, newURI: item.uri)
                    if refreshed >= 10_000 {
                        try execute("UPDATE sync_state SET reconcile_status = 'required:descendant_move' WHERE singleton = 1")
                    }
                }
                let changed = try executeReturningChanges("UPDATE operations SET state = '\(sql(state))', item_uuid = '\(sql(item.itemIdentifier))', outcome = \(nullable(encodedOutcome)), lease_owner = NULL, lease_expires_at = NULL, updated_at = unixepoch() WHERE operation_id = '\(operationID.uuidString)'")
                guard changed == 1 else { throw StoreBridgeError.sql("operation missing during atomic commit") }
                if state == "committed" {
                    try execute("DELETE FROM pending_items WHERE item_uuid = '\(sql(item.itemIdentifier))'")
                    try execute("UPDATE item_local_state SET upload_state = 'none', download_state = 'none', upload_error = NULL, download_error = NULL, updated_at = unixepoch() WHERE item_uuid = '\(sql(item.itemIdentifier))'")
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func commitProviderChanges(_ inputs: [ProviderChangeInput]) throws -> [JournalChange] {
        let folded = JournalChangeFold.fold(inputs)
        guard !folded.isEmpty else { return [] }
        return try withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                var result: [JournalChange] = []
                for input in folded {
                    let existing = try itemUnlockedForProjection(identifier: input.item.itemIdentifier)
                    let isViewChange = input.kind == "view_removed" || input.kind == "view_added"
                    let viewStateAlreadyMatches: Bool
                    if isViewChange {
                        viewStateAlreadyMatches = (try localStateUnlocked(identifier: input.item.itemIdentifier).viewExcluded) == (input.kind == "view_removed")
                    } else {
                        viewStateAlreadyMatches = true
                    }
                    if let existing,
                       existing == input.item,
                       input.oldParentIdentifier == input.item.parentIdentifier,
                       input.newParentIdentifier == input.item.parentIdentifier,
                       viewStateAlreadyMatches {
                        continue
                    }
                    if isViewChange {
                        try invalidateDirectorySnapshotsUnlocked()
                    }
                    try insertItemUnlocked(input.item)
                    if input.kind == "view_removed" || input.kind == "view_added" {
                        var state = try localStateUnlocked(identifier: input.item.itemIdentifier)
                        state.viewExcluded = input.kind == "view_removed"
                        try upsertLocalStateUnlocked(identifier: input.item.itemIdentifier, state: state)
                    }
                    let payload = try encodeJournalPayload(input.item)
                    result.append(try appendProviderChangeUnlocked(
                        itemIdentifier: input.item.itemIdentifier,
                        oldParentIdentifier: input.oldParentIdentifier,
                        newParentIdentifier: input.newParentIdentifier,
                        kind: input.kind,
                        version: input.item.version.content,
                        origin: input.origin,
                        itemPayload: payload,
                        itemVersion: input.item.version
                    ))
                    if input.item.kind == .folder,
                       let existing,
                       existing.uri != input.item.uri {
                        let refreshed = try refreshDescendantURIsUnlocked(rootIdentifier: input.item.itemIdentifier, oldURI: existing.uri, newURI: input.item.uri)
                        if refreshed >= 10_000 {
                            try execute("UPDATE sync_state SET reconcile_status = 'required:descendant_move' WHERE singleton = 1")
                        }
                    }
                }
                try execute("COMMIT")
                return result
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    @discardableResult
    func refreshDescendantURIs(rootIdentifier: String, oldURI: String, newURI: String, limit: Int = 10_000) throws -> Int {
        try withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                let count = try refreshDescendantURIsUnlocked(rootIdentifier: rootIdentifier, oldURI: oldURI, newURI: newURI, limit: limit)
                if count >= min(max(1, limit), 50_000) {
                    try execute("UPDATE sync_state SET reconcile_status = 'required:descendant_move' WHERE singleton = 1")
                }
                try execute("COMMIT")
                return count
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    /// Updates descendants while the caller owns the current transaction.
    /// This is intentionally separate from refreshDescendantURIs so an
    /// operation result can publish its parent, descendants, journal and
    /// outbox as one durable commit.
    func refreshDescendantURIsUnlocked(rootIdentifier: String, oldURI: String, newURI: String, limit: Int = 10_000) throws -> Int {
        let boundedLimit = max(1, min(limit, 50_000))
        let statement = try prepare("""
        SELECT item_uuid, remote_entity_id, parent_uuid, trash_original_parent_uuid, remote_name, kind, current_remote_uri, size, remote_version, content_version, metadata_version, trashed, tombstone, created_at, modified_at, can_read, can_write, can_add_children, can_trash, can_delete, content_type
        FROM items
        WHERE current_remote_uri = '\(sql(oldURI))' OR (LENGTH(current_remote_uri) > LENGTH('\(sql(oldURI))') + 1 AND SUBSTR(current_remote_uri, 1, LENGTH('\(sql(oldURI))') + 1) = '\(sql(oldURI + "/"))')
        ORDER BY LENGTH(current_remote_uri) ASC, item_uuid ASC
        LIMIT \(boundedLimit)
        """)
        defer { sqlite3_finalize(statement) }
        var items: [RemoteItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var item = itemFromStatement(statement)
            guard item.itemIdentifier != rootIdentifier, item.uri == oldURI || item.uri.hasPrefix(oldURI + "/") else { continue }
            let suffix = String(item.uri.dropFirst(oldURI.count))
            item.uri = newURI + suffix
            items.append(item)
        }
        for item in items {
            try insertItemUnlocked(item)
            let payload = try encodeJournalPayload(item)
            _ = try appendProviderChangeUnlocked(itemIdentifier: item.itemIdentifier, oldParentIdentifier: item.parentIdentifier, newParentIdentifier: item.parentIdentifier, kind: "moved_descendant", version: item.version.content, origin: "remote_move", itemPayload: payload, itemVersion: item.version)
        }
        return items.count
    }

    /// Marks known descendants as tombstones before the parent tombstone is
    /// appended. The child-first sequence ordering lets File Provider remove
    /// nested items without briefly leaving a stale child under a deleted
    /// directory.
    func tombstoneDescendantsUnlocked(rootIdentifier: String, oldURI: String, limit: Int = 100_000) throws -> Int {
        let boundedLimit = max(1, min(limit, 100_000))
        let statement = try prepare("""
        SELECT item_uuid, remote_entity_id, parent_uuid, trash_original_parent_uuid, remote_name, kind, current_remote_uri, size, remote_version, content_version, metadata_version, trashed, tombstone, created_at, modified_at, can_read, can_write, can_add_children, can_trash, can_delete, content_type
        FROM items
        WHERE tombstone = 0
          AND LENGTH(current_remote_uri) > LENGTH('\(sql(oldURI))') + 1
          AND SUBSTR(current_remote_uri, 1, LENGTH('\(sql(oldURI))') + 1) = '\(sql(oldURI + "/"))'
        ORDER BY LENGTH(current_remote_uri) DESC, item_uuid ASC
        LIMIT \(boundedLimit)
        """)
        defer { sqlite3_finalize(statement) }
        var items: [RemoteItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var item = itemFromStatement(statement)
            item.tombstone = true
            items.append(item)
        }
        for item in items {
            try insertItemUnlocked(item)
            let payload = try encodeJournalPayload(item)
            _ = try appendProviderChangeUnlocked(
                itemIdentifier: item.itemIdentifier,
                oldParentIdentifier: item.parentIdentifier,
                newParentIdentifier: nil,
                kind: "deleted",
                version: item.version.content,
                origin: "recursive_delete",
                itemPayload: payload,
                itemVersion: item.version
            )
        }
        return items.count
    }

    func itemProjection(identifier: String) throws -> ItemProjection? {
        try withLock {
            let statement = try prepare("SELECT item_uuid, remote_entity_id, parent_uuid, trash_original_parent_uuid, remote_name, kind, current_remote_uri, size, remote_version, content_version, metadata_version, trashed, tombstone, created_at, modified_at, can_read, can_write, can_add_children, can_trash, can_delete, content_type FROM items WHERE item_uuid = '\(sql(identifier))' LIMIT 1")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            let item = itemFromStatement(statement)
            let localState = try localStateUnlocked(identifier: identifier)
            let effectiveKeepPolicy = try effectiveKeepDownloadedPolicyUnlocked(identifier: identifier)
            let metadataCapability = try metadataMoveAllowedUnlocked()
            let metadataMoveAllowed = item.canWrite && metadataCapability
            let operationState = try scalar("SELECT state FROM operations WHERE item_uuid = '\(sql(identifier))' AND history_hidden = 0 ORDER BY updated_at DESC LIMIT 1")
            let conflict = try scalar("SELECT 1 FROM conflicts WHERE item_uuid = '\(sql(identifier))' AND state = 'pending' LIMIT 1") == "1"
            let childCount: Int64?
            if item.kind == .folder, let parent = try completeSnapshotDescriptorUnlocked(parentIdentifier: identifier), parent.state == "complete", parent.expiresAt > Date() {
                childCount = Int64(try scalar("SELECT COUNT(*) FROM directory_snapshot_items s LEFT JOIN item_local_state l ON l.item_uuid = s.item_uuid LEFT JOIN items i ON i.item_uuid = s.item_uuid WHERE s.snapshot_id = '\(sql(parent.snapshotID))' AND COALESCE(l.view_excluded, 0) = 0 AND COALESCE(i.trashed, 0) = 0 AND COALESCE(i.tombstone, 0) = 0") ?? "0")
            } else {
                childCount = nil
            }
            return ItemProjection(item: item, localState: localState, effectiveKeepPolicy: effectiveKeepPolicy, metadataMoveAllowed: metadataMoveAllowed, operationState: operationState, childItemCount: childCount, hasConflict: conflict)
        }
    }

    func localItemState(identifier: String) throws -> ItemLocalState {
        try withLock { try localStateUnlocked(identifier: identifier) }
    }

    func setLocalItemState(identifier: String, state: ItemLocalState) throws {
        try withLock {
            try execute("""
            INSERT INTO item_local_state (item_uuid, materialized, visited, keep_policy, upload_state, download_state, upload_error, download_error, system_visible, view_excluded, last_used_at, updated_at)
            VALUES ('\(sql(identifier))', \(state.materialized ? 1 : 0), \(state.visited ? 1 : 0), '\(state.keepPolicy.rawValue)', '\(state.uploadState.rawValue)', '\(state.downloadState.rawValue)', \(nullable(state.uploadError)), \(nullable(state.downloadError)), \(state.systemVisible ? 1 : 0), \(state.viewExcluded ? 1 : 0), \(state.lastUsedAt.map { String(Int64($0.timeIntervalSince1970)) } ?? "NULL"), unixepoch())
            ON CONFLICT(item_uuid) DO UPDATE SET materialized = excluded.materialized, visited = excluded.visited, keep_policy = excluded.keep_policy, upload_state = excluded.upload_state, download_state = excluded.download_state, upload_error = excluded.upload_error, download_error = excluded.download_error, system_visible = excluded.system_visible, view_excluded = excluded.view_excluded, last_used_at = excluded.last_used_at, updated_at = unixepoch()
            """)
        }
    }

    func markVisitedContainer(_ identifier: String, systemVisible: Bool = true) throws {
        try withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("INSERT INTO visited_containers (item_uuid, last_seen_generation, system_visible, updated_at) VALUES ('\(sql(identifier))', 0, \(systemVisible ? 1 : 0), unixepoch()) ON CONFLICT(item_uuid) DO UPDATE SET system_visible = excluded.system_visible, updated_at = unixepoch()")
                var state = try localStateUnlocked(identifier: identifier)
                state.visited = true
                state.systemVisible = state.systemVisible || systemVisible
                try upsertLocalStateUnlocked(identifier: identifier, state: state)
                try bumpWorkingSetRevisionUnlocked()
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func unmarkVisitedContainer(_ identifier: String) throws {
        try withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("UPDATE visited_containers SET system_visible = 0, updated_at = unixepoch() WHERE item_uuid = '\(sql(identifier))'")
                var state = try localStateUnlocked(identifier: identifier)
                state.visited = false
                try upsertLocalStateUnlocked(identifier: identifier, state: state)
                try bumpWorkingSetRevisionUnlocked()
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func visitedContainerIdentifiers() throws -> Set<String> {
        try withLock {
            let statement = try prepare("SELECT item_uuid FROM visited_containers WHERE system_visible = 1")
            defer { sqlite3_finalize(statement) }
            var result = Set<String>()
            while sqlite3_step(statement) == SQLITE_ROW {
                if let identifier = columnString(statement, 0) { result.insert(identifier) }
            }
            return result
        }
    }

    func workingSetRevision() throws -> UInt64 {
        try withLock { UInt64(max(0, Int64(try scalar("SELECT domain_version_revision FROM sync_state WHERE singleton = 1") ?? "0") ?? 0)) }
    }

    private func currentDomainRootPredicate(alias: String) -> String {
        let root = "(SELECT root_uri FROM domains ORDER BY domain_id LIMIT 1)"
        return "(NOT EXISTS (SELECT 1 FROM domains) OR \(alias).current_remote_uri NOT LIKE 'cloudreve://%' OR \(alias).current_remote_uri = \(root) OR (LENGTH(\(alias).current_remote_uri) > LENGTH(\(root)) + 1 AND SUBSTR(\(alias).current_remote_uri, 1, LENGTH(\(root)) + 1) = \(root) || '/'))"
    }

    func workingSetItems(afterIdentifier: String? = nil, limit: Int = 200) throws -> [RemoteItem] {
        try withLock {
            let boundedLimit = max(1, min(limit, 4_000))
            let afterClause = afterIdentifier.map { "AND i.item_uuid > '\(sql($0))'" } ?? ""
            let statement = try prepare("""
            SELECT i.item_uuid, i.remote_entity_id, i.parent_uuid, i.trash_original_parent_uuid, i.remote_name, i.kind, i.current_remote_uri, i.size, i.remote_version, i.content_version, i.metadata_version, i.trashed, i.tombstone, i.created_at, i.modified_at, i.can_read, i.can_write, i.can_add_children, i.can_trash, i.can_delete, i.content_type
            FROM items i
            LEFT JOIN item_local_state l ON l.item_uuid = i.item_uuid
            WHERE i.tombstone = 0 AND (i.trashed = 0 OR i.parent_uuid = '\(NSFileProviderItemIdentifier.trashContainer.rawValue)') AND COALESCE(l.view_excluded, 0) = 0 AND \(currentDomainRootPredicate(alias: "i"))
              AND (
                i.parent_uuid = '\(NSFileProviderItemIdentifier.rootContainer.rawValue)'
                OR i.parent_uuid = '\(NSFileProviderItemIdentifier.trashContainer.rawValue)'
                OR COALESCE(l.materialized, 0) = 1
                OR COALESCE(l.visited, 0) = 1
                OR COALESCE(l.system_visible, 0) = 1
                OR EXISTS (SELECT 1 FROM pending_items p WHERE p.item_uuid = i.item_uuid)
                OR EXISTS (SELECT 1 FROM operations o WHERE o.item_uuid = i.item_uuid AND o.state NOT IN ('committed', 'cancelled', 'permanently_failed', 'resolved'))
                OR EXISTS (SELECT 1 FROM conflicts c WHERE c.item_uuid = i.item_uuid AND c.state = 'pending')
                OR EXISTS (SELECT 1 FROM item_local_state parent_state WHERE parent_state.item_uuid = i.parent_uuid AND (parent_state.materialized = 1 OR parent_state.visited = 1 OR parent_state.system_visible = 1))
              )
              \(afterClause)
            ORDER BY i.item_uuid ASC
            LIMIT \(boundedLimit)
            """)
            defer { sqlite3_finalize(statement) }
            var result: [RemoteItem] = []
            while sqlite3_step(statement) == SQLITE_ROW { result.append(itemFromStatement(statement)) }
            return result
        }
    }

    func isWorkingSetMember(identifier: String) throws -> Bool {
        try withLock {
            let query = """
            SELECT 1
            FROM items i
            LEFT JOIN item_local_state l ON l.item_uuid = i.item_uuid
            WHERE i.item_uuid = '\(sql(identifier))'
              AND i.tombstone = 0
              AND (i.trashed = 0 OR i.parent_uuid = '\(NSFileProviderItemIdentifier.trashContainer.rawValue)')
              AND COALESCE(l.view_excluded, 0) = 0
              AND \(currentDomainRootPredicate(alias: "i"))
              AND (
                i.parent_uuid = '\(NSFileProviderItemIdentifier.rootContainer.rawValue)'
                OR i.parent_uuid = '\(NSFileProviderItemIdentifier.trashContainer.rawValue)'
                OR COALESCE(l.materialized, 0) = 1
                OR COALESCE(l.visited, 0) = 1
                OR COALESCE(l.system_visible, 0) = 1
                OR EXISTS (SELECT 1 FROM pending_items p WHERE p.item_uuid = i.item_uuid)
                OR EXISTS (SELECT 1 FROM operations o WHERE o.item_uuid = i.item_uuid AND o.state NOT IN ('committed', 'cancelled', 'permanently_failed', 'resolved'))
                OR EXISTS (SELECT 1 FROM conflicts c WHERE c.item_uuid = i.item_uuid AND c.state = 'pending')
                OR EXISTS (SELECT 1 FROM item_local_state parent_state WHERE parent_state.item_uuid = i.parent_uuid AND (parent_state.materialized = 1 OR parent_state.visited = 1 OR parent_state.system_visible = 1))
              )
            LIMIT 1
            """
            return (try scalar(query) ?? "0") == "1"
        }
    }

    func allItems(limit: Int = 100_000, includeTombstones: Bool = false) throws -> [RemoteItem] {
        try withLock {
            let tombstoneClause = includeTombstones ? "" : "WHERE tombstone = 0"
            let statement = try prepare("""
            SELECT item_uuid, remote_entity_id, parent_uuid, trash_original_parent_uuid, remote_name, kind, current_remote_uri, size, remote_version, content_version, metadata_version, trashed, tombstone, created_at, modified_at, can_read, can_write, can_add_children, can_trash, can_delete, content_type
            FROM items \(tombstoneClause)
            ORDER BY item_uuid ASC
            LIMIT \(max(1, min(limit, 100_000)))
            """)
            defer { sqlite3_finalize(statement) }
            var result: [RemoteItem] = []
            while sqlite3_step(statement) == SQLITE_ROW { result.append(itemFromStatement(statement)) }
            return result
        }
    }

    func completeChildItemCount(parentIdentifier: String) throws -> Int64? {
        try withLock {
            guard let snapshot = try completeSnapshotDescriptorUnlocked(parentIdentifier: parentIdentifier), snapshot.state == "complete", snapshot.expiresAt > Date() else { return nil }
            return Int64(try scalar("SELECT COUNT(*) FROM directory_snapshot_items s LEFT JOIN item_local_state l ON l.item_uuid = s.item_uuid LEFT JOIN items i ON i.item_uuid = s.item_uuid WHERE s.snapshot_id = '\(sql(snapshot.snapshotID))' AND COALESCE(l.view_excluded, 0) = 0 AND COALESCE(i.trashed, 0) = 0 AND COALESCE(i.tombstone, 0) = 0") ?? "0")
        }
    }

    @discardableResult
    func setViewExcludedAndJournal(identifier: String, excluded: Bool, origin: String = "exclusion") throws -> JournalChange? {
        try withLock {
            guard var state = try? localStateUnlocked(identifier: identifier), let item = try itemUnlockedForProjection(identifier: identifier) else { return nil }
            guard state.viewExcluded != excluded else { return nil }
            try execute("BEGIN IMMEDIATE")
            do {
                state.viewExcluded = excluded
                try invalidateDirectorySnapshotsUnlocked()
                try upsertLocalStateUnlocked(identifier: identifier, state: state)
                let payload = try encodeJournalPayload(item)
                let change = try appendProviderChangeUnlocked(itemIdentifier: item.itemIdentifier, oldParentIdentifier: item.parentIdentifier, newParentIdentifier: item.parentIdentifier, kind: excluded ? "view_removed" : "view_added", version: item.version.content, origin: origin, itemPayload: payload, itemVersion: item.version)
                try execute("COMMIT")
                return change
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func trashItems() throws -> [RemoteItem] {
        try withLock {
            let statement = try prepare("SELECT i.item_uuid, i.remote_entity_id, i.parent_uuid, i.trash_original_parent_uuid, i.remote_name, i.kind, i.current_remote_uri, i.size, i.remote_version, i.content_version, i.metadata_version, i.trashed, i.tombstone, i.created_at, i.modified_at, i.can_read, i.can_write, i.can_add_children, i.can_trash, i.can_delete, i.content_type FROM items i WHERE i.trashed = 1 AND i.parent_uuid = '\(NSFileProviderItemIdentifier.trashContainer.rawValue)' AND i.tombstone = 0 AND \(currentDomainRootPredicate(alias: "i")) ORDER BY i.remote_name COLLATE NOCASE, i.item_uuid")
            defer { sqlite3_finalize(statement) }
            var result: [RemoteItem] = []
            while sqlite3_step(statement) == SQLITE_ROW { result.append(itemFromStatement(statement)) }
            return result
        }
    }

    func beginDirectorySnapshot(domainIdentifier: String, parentIdentifier: String, ttl: TimeInterval = 3_600, serverToken: Data? = nil) throws -> DirectorySnapshotDescriptor {
        try withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("DELETE FROM directory_snapshot_generations WHERE state = 'collecting' AND expires_at <= unixepoch()")
                try execute("DELETE FROM directory_snapshot_generations WHERE state = 'complete' AND expires_at <= unixepoch() AND snapshot_id NOT IN (SELECT current_snapshot_id FROM directory_snapshot_heads)")
                try execute("UPDATE directory_snapshot_generations SET state = 'abandoned', updated_at = unixepoch() WHERE domain_id = '\(sql(domainIdentifier))' AND parent_uuid = '\(sql(parentIdentifier))' AND state = 'collecting'")
                try execute("DELETE FROM directory_snapshot_generations WHERE state = 'abandoned' AND updated_at <= unixepoch() - 86_400 AND snapshot_id NOT IN (SELECT current_snapshot_id FROM directory_snapshot_heads)")
                let current = Int64(try scalar("SELECT COALESCE(MAX(generation), 0) FROM directory_snapshot_generations WHERE domain_id = '\(sql(domainIdentifier))' AND parent_uuid = '\(sql(parentIdentifier))'") ?? "0") ?? 0
                let generation = current + 1
                let snapshotID = UUID().uuidString
                let expiresAt = Date().addingTimeInterval(max(60, ttl))
                try execute("INSERT INTO directory_snapshot_generations (snapshot_id, domain_id, parent_uuid, generation, server_snapshot_token, next_cursor, state, item_count, expires_at) VALUES ('\(snapshotID)', '\(sql(domainIdentifier))', '\(sql(parentIdentifier))', \(generation), \(serverToken.map { "X'\($0.hexString)'" } ?? "NULL"), NULL, 'collecting', 0, \(Int64(expiresAt.timeIntervalSince1970)))")
                try execute("COMMIT")
                return DirectorySnapshotDescriptor(snapshotID: snapshotID, domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier, generation: UInt64(generation), expiresAt: expiresAt, state: "collecting")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func activeDirectorySnapshot(domainIdentifier: String, parentIdentifier: String) throws -> DirectorySnapshotDescriptor? {
        try withLock {
            let statement = try prepare("SELECT snapshot_id, domain_id, parent_uuid, generation, expires_at, state, next_cursor FROM directory_snapshot_generations WHERE domain_id = '\(sql(domainIdentifier))' AND parent_uuid = '\(sql(parentIdentifier))' AND state = 'collecting' AND expires_at > unixepoch() ORDER BY generation DESC LIMIT 1")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return DirectorySnapshotDescriptor(snapshotID: columnString(statement, 0) ?? "", domainIdentifier: columnString(statement, 1) ?? domainIdentifier, parentIdentifier: columnString(statement, 2) ?? parentIdentifier, generation: UInt64(max(0, sqlite3_column_int64(statement, 3))), expiresAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 4))), state: columnString(statement, 5) ?? "collecting", nextCursor: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : columnBlob(statement, 6))
        }
    }

    func currentCompleteDirectorySnapshot(domainIdentifier: String, parentIdentifier: String) throws -> DirectorySnapshotDescriptor? {
        try withLock {
            let statement = try prepare("SELECT current_snapshot_id FROM directory_snapshot_heads h JOIN directory_snapshot_generations g ON g.snapshot_id = h.current_snapshot_id WHERE h.domain_id = '\(sql(domainIdentifier))' AND h.parent_uuid = '\(sql(parentIdentifier))' AND g.state = 'complete' AND g.expires_at > unixepoch() LIMIT 1")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let snapshotID = columnString(statement, 0) else { return nil }
            return try snapshotDescriptorUnlocked(snapshotID: snapshotID)
        }
    }

    func appendDirectorySnapshotItems(snapshotID: String, items: [RemoteItem], nextCursor: Data? = nil) throws {
        guard !items.isEmpty || nextCursor != nil else { return }
        try withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                let descriptor = try snapshotDescriptorUnlocked(snapshotID: snapshotID)
                guard descriptor.state == "collecting", descriptor.expiresAt > Date() else { throw StoreBridgeError.generationFenced }
                var nextIndex = Int64(try scalar("SELECT COALESCE(MAX(order_index) + 1, 0) FROM directory_snapshot_items WHERE snapshot_id = '\(sql(snapshotID))'") ?? "0") ?? 0
                let existingCount = Int64(try scalar("SELECT COUNT(*) FROM directory_snapshot_items WHERE snapshot_id = '\(sql(snapshotID))'") ?? "0") ?? 0
                let existingBytes = Int64(try scalar("SELECT COALESCE(SUM(LENGTH(item_payload)), 0) FROM directory_snapshot_items WHERE snapshot_id = '\(sql(snapshotID))'") ?? "0") ?? 0
                var addedCount: Int64 = 0
                var addedBytes: Int64 = 0
                for item in items {
                    let stagedItem = item
                    if try isExcludedByCurrentRulesUnlocked(item: stagedItem, domainIdentifier: descriptor.domainIdentifier) {
                        var state = try localStateUnlocked(identifier: stagedItem.itemIdentifier)
                        state.viewExcluded = true
                        try upsertLocalStateUnlocked(identifier: stagedItem.itemIdentifier, state: state)
                    }
                    let payload = try JSONEncoder().encode(stagedItem)
                    guard payload.count <= 64 * 1024 else { throw StoreBridgeError.sql("snapshot payload exceeds 64 KiB") }
                    try insertItemUnlocked(stagedItem)
                    guard (try scalar("SELECT 1 FROM directory_snapshot_items WHERE snapshot_id = '\(sql(snapshotID))' AND item_uuid = '\(sql(stagedItem.itemIdentifier))' LIMIT 1")) == nil else { continue }
                    guard existingCount + addedCount + 1 <= 100_000, existingBytes + addedBytes + Int64(payload.count) <= 256 * 1024 * 1024 else {
                        throw StoreBridgeError.sql("directory snapshot capacity exceeded")
                    }
                    try execute("INSERT INTO directory_snapshot_items (snapshot_id, order_index, item_uuid, item_payload) VALUES ('\(sql(snapshotID))', \(nextIndex), '\(sql(stagedItem.itemIdentifier))', X'\(payload.hexString)')")
                    nextIndex += 1
                    addedCount += 1
                    addedBytes += Int64(payload.count)
                }
                try execute("UPDATE directory_snapshot_generations SET next_cursor = \(nextCursor.map { "X'\($0.hexString)'" } ?? "NULL"), item_count = (SELECT COUNT(*) FROM directory_snapshot_items WHERE snapshot_id = '\(sql(snapshotID))'), updated_at = unixepoch() WHERE snapshot_id = '\(sql(snapshotID))' AND state = 'collecting'")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func publishDirectorySnapshot(snapshotID: String) throws {
        try withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                let descriptor = try snapshotDescriptorUnlocked(snapshotID: snapshotID)
                guard descriptor.expiresAt > Date() else { throw StoreBridgeError.snapshotExpired }
                let changed = try executeReturningChanges("UPDATE directory_snapshot_generations SET state = 'complete', next_cursor = NULL, updated_at = unixepoch() WHERE snapshot_id = '\(sql(snapshotID))' AND state = 'collecting'")
                guard changed == 1 else { throw StoreBridgeError.generationFenced }
                try execute("INSERT INTO directory_snapshot_heads (domain_id, parent_uuid, current_snapshot_id, current_generation) VALUES ('\(sql(descriptor.domainIdentifier))', '\(sql(descriptor.parentIdentifier))', '\(sql(snapshotID))', \(descriptor.generation)) ON CONFLICT(domain_id, parent_uuid) DO UPDATE SET current_snapshot_id = excluded.current_snapshot_id, current_generation = excluded.current_generation")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func directorySnapshotPage(domainIdentifier: String, parentIdentifier: String, generation: UInt64, snapshotID: String? = nil, offset: Int, limit: Int) throws -> DirectoryPage {
        try withLock {
            let identifier: String?
            if let snapshotID { identifier = snapshotID } else {
                identifier = try scalar("SELECT current_snapshot_id FROM directory_snapshot_heads WHERE domain_id = '\(sql(domainIdentifier))' AND parent_uuid = '\(sql(parentIdentifier))' AND current_generation = \(generation) LIMIT 1")
            }
            guard let identifier else { throw StoreBridgeError.snapshotExpired }
            let descriptor = try snapshotDescriptorUnlocked(snapshotID: identifier)
            guard descriptor.domainIdentifier == domainIdentifier, descriptor.parentIdentifier == parentIdentifier, descriptor.generation == generation, descriptor.state == "complete" else { throw StoreBridgeError.pageTokenInvalid }
            guard descriptor.expiresAt > Date() else { throw StoreBridgeError.snapshotExpired }
            let boundedLimit = max(1, min(limit, 500))
            // Apply the current local view filter at read time as well as at
            // hydration time. Rules can change while an immutable snapshot is
            // still within its TTL; a hidden item must not reappear merely
            // because the page was already staged.
            let statement = try prepare("SELECT s.item_payload FROM directory_snapshot_items s LEFT JOIN item_local_state l ON l.item_uuid = s.item_uuid LEFT JOIN items i ON i.item_uuid = s.item_uuid WHERE s.snapshot_id = '\(sql(identifier))' AND COALESCE(l.view_excluded, 0) = 0 AND COALESCE(i.trashed, 0) = 0 AND COALESCE(i.tombstone, 0) = 0 ORDER BY s.order_index LIMIT \(boundedLimit + 1) OFFSET \(max(0, offset))")
            defer { sqlite3_finalize(statement) }
            var items: [RemoteItem] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let item = try? JSONDecoder().decode(RemoteItem.self, from: columnBlob(statement, 0)) { items.append(item) }
            }
            let hasMore = items.count > boundedLimit
            if hasMore { items.removeLast() }
            return DirectoryPage(items: items, nextOffset: hasMore ? offset + items.count : nil, generation: generation, complete: !hasMore, snapshotID: identifier, expiresAt: descriptor.expiresAt)
        }
    }

    func systemSetState(setKind: String) throws -> SystemSetState? {
        try withLock {
            let statement = try prepare("SELECT set_kind, current_generation, active_generation, refresh_required, scan_state, maximum_size_reached, refresh_cursor, last_completed_at FROM system_set_state WHERE set_kind = '\(sql(setKind))' LIMIT 1")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return SystemSetState(setKind: columnString(statement, 0) ?? setKind, currentGeneration: sqlite3_column_int64(statement, 1), activeGeneration: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 2), refreshRequired: sqlite3_column_int(statement, 3) != 0, scanState: columnString(statement, 4) ?? "idle", maximumSizeReached: sqlite3_column_int(statement, 5) != 0, cursor: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : columnBlob(statement, 6), lastCompletedAt: sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 7))))
        }
    }

    func claimSystemSet(setKind: String, ownerID: UUID = UUID(), domainVersion: Data? = nil, staleAfter: TimeInterval = 30) throws -> SystemSetClaim? {
        try withLock {
            try execute("INSERT OR IGNORE INTO system_set_state (set_kind, refresh_required, current_generation, scan_state, maximum_size_reached) VALUES ('\(sql(setKind))', 1, 0, 'idle', 0)")
            let current = Int64(try scalar("SELECT current_generation FROM system_set_state WHERE set_kind = '\(sql(setKind))' LIMIT 1") ?? "0") ?? 0
            let existingActive = Int64(try scalar("SELECT active_generation FROM system_set_state WHERE set_kind = '\(sql(setKind))' LIMIT 1") ?? "0") ?? 0
            let existingDomainVersion: Data?
            do {
                let statement = try prepare("SELECT domain_version FROM system_set_state WHERE set_kind = '\(sql(setKind))' LIMIT 1")
                defer { sqlite3_finalize(statement) }
                existingDomainVersion = sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_type(statement, 0) != SQLITE_NULL ? columnBlob(statement, 0) : nil
            }
            let domainVersionChanged = domainVersion != nil && existingDomainVersion != domainVersion
            let next = existingActive > 0 && !domainVersionChanged ? existingActive : current + 1
            let cutoff = Int64(Date().timeIntervalSince1970 - max(1, staleAfter))
            let changed = try executeReturningChanges("""
            UPDATE system_set_state SET active_generation = \(next), active_owner = '\(ownerID.uuidString)', active_started_at = unixepoch(), scan_state = 'collecting', refresh_required = 1, refresh_cursor = \(domainVersionChanged ? "NULL" : "refresh_cursor"), domain_version = \(domainVersion.map { "X'\($0.hexString)'" } ?? "domain_version"), updated_at = unixepoch()
            WHERE set_kind = '\(sql(setKind))' AND (active_owner IS NULL OR active_started_at IS NULL OR active_started_at < \(cutoff))
            """)
            guard changed == 1 else { return nil }
            if (existingActive == 0 || domainVersionChanged) && setKind == "materialized" {
                try execute("UPDATE materialized_containers SET observed_generation = NULL WHERE state_source = 'system'")
            } else if (existingActive == 0 || domainVersionChanged) && setKind == "pending" {
                try execute("UPDATE system_pending_observations SET observed_generation = NULL, observed_payload = NULL WHERE is_pending = 1")
            }
            return SystemSetClaim(setKind: setKind, generation: next, ownerID: ownerID, domainVersion: domainVersion)
        }
    }

    func setSystemSetCursor(claim: SystemSetClaim, cursor: Data?) throws {
        try withLock {
            let domainClause = claim.domainVersion.map { " AND domain_version = X'\($0.hexString)'" } ?? ""
            let changed = try executeReturningChanges("UPDATE system_set_state SET refresh_cursor = \(cursor.map { "X'\($0.hexString)'" } ?? "NULL"), updated_at = unixepoch() WHERE set_kind = '\(sql(claim.setKind))' AND active_generation = \(claim.generation) AND active_owner = '\(claim.ownerID.uuidString)'\(domainClause)")
            guard changed == 1 else { throw StoreBridgeError.generationFenced }
        }
    }

    func releaseSystemSetClaim(claim: SystemSetClaim, cursor: Data? = nil) throws {
        try withLock {
            let domainClause = claim.domainVersion.map { " AND domain_version = X'\($0.hexString)'" } ?? ""
            let changed = try executeReturningChanges("UPDATE system_set_state SET active_generation = NULL, active_owner = NULL, active_started_at = NULL, scan_state = 'failed', refresh_required = 1, refresh_cursor = \(cursor.map { "X'\($0.hexString)'" } ?? "refresh_cursor"), updated_at = unixepoch() WHERE set_kind = '\(sql(claim.setKind))' AND active_generation = \(claim.generation) AND active_owner = '\(claim.ownerID.uuidString)'\(domainClause)")
            guard changed == 1 else { throw StoreBridgeError.generationFenced }
        }
    }

    func observeMaterializedItem(_ identifier: String, claim: SystemSetClaim) throws {
        try withLock {
            let domainClause = claim.domainVersion.map { " AND domain_version = X'\($0.hexString)'" } ?? ""
            guard try scalar("SELECT active_generation FROM system_set_state WHERE set_kind = '\(sql(claim.setKind))' AND active_owner = '\(claim.ownerID.uuidString)'\(domainClause) LIMIT 1") == String(claim.generation) else { throw StoreBridgeError.generationFenced }
            let changed = try executeReturningChanges("UPDATE materialized_containers SET observed_generation = \(claim.generation), state_source = 'system', updated_at = unixepoch() WHERE item_uuid = '\(sql(identifier))'")
            if changed == 0 {
                try execute("INSERT INTO materialized_containers (item_uuid, is_materialized, observed_generation, state_source, updated_at) VALUES ('\(sql(identifier))', 0, \(claim.generation), 'system', unixepoch())")
            }
            try bumpWorkingSetRevisionUnlocked()
        }
    }

    func observePendingItem(_ identifier: String, payload: Data?, claim: SystemSetClaim) throws {
        try withLock {
            let domainClause = claim.domainVersion.map { " AND domain_version = X'\($0.hexString)'" } ?? ""
            guard try scalar("SELECT active_generation FROM system_set_state WHERE set_kind = '\(sql(claim.setKind))' AND active_owner = '\(claim.ownerID.uuidString)'\(domainClause) LIMIT 1") == String(claim.generation) else { throw StoreBridgeError.generationFenced }
            if let payload, payload.count > 64 * 1024 {
                throw StoreBridgeError.sql("system pending observation exceeds 64 KiB")
            }
            try execute("INSERT INTO system_pending_observations (item_uuid, is_pending, observed_generation, observed_payload, updated_at) VALUES ('\(sql(identifier))', 1, \(claim.generation), \(payload.map { "X'\($0.hexString)'" } ?? "NULL"), unixepoch()) ON CONFLICT(item_uuid) DO UPDATE SET is_pending = 1, observed_generation = excluded.observed_generation, observed_payload = excluded.observed_payload, updated_at = unixepoch()")
            var state = try localStateUnlocked(identifier: identifier)
            state.systemVisible = true
            if let payload, let values = try? JSONSerialization.jsonObject(with: payload) as? [String: String] {
                if let uploadError = values["uploadError"] {
                    state.uploadState = .failed
                    state.uploadError = uploadError
                }
                if let downloadError = values["downloadError"] {
                    state.downloadState = .failed
                    state.downloadError = downloadError
                }
            }
            if state.uploadState == .none { state.uploadState = .queued }
            try upsertLocalStateUnlocked(identifier: identifier, state: state)
            try execute("UPDATE conflicts SET source_generation = \(claim.generation), updated_at = unixepoch() WHERE item_uuid = '\(sql(identifier))' AND state = 'pending' AND local_source_kind = 'system_pending'")
            try bumpWorkingSetRevisionUnlocked()
        }
    }

    func publishMaterializedSet(claim: SystemSetClaim, complete: Bool, anchor: Data? = nil, cursor: Data? = nil) throws {
        try withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                let domainClause = claim.domainVersion.map { " AND domain_version = X'\($0.hexString)'" } ?? ""
                guard try scalar("SELECT active_generation FROM system_set_state WHERE set_kind = '\(sql(claim.setKind))' AND active_owner = '\(claim.ownerID.uuidString)'\(domainClause) LIMIT 1") == String(claim.generation) else { throw StoreBridgeError.generationFenced }
                if complete {
                    try bumpWorkingSetRevisionUnlocked()
                    try execute("UPDATE materialized_containers SET is_materialized = 0, state_source = 'system', updated_at = unixepoch() WHERE state_source IN ('system', 'fetch_hint') AND (observed_generation IS NULL OR observed_generation != \(claim.generation))")
                    try execute("UPDATE materialized_containers SET is_materialized = 1, observed_generation = NULL, state_source = 'system', updated_at = unixepoch() WHERE observed_generation = \(claim.generation)")
                    try execute("UPDATE item_local_state SET materialized = 0, updated_at = unixepoch() WHERE item_uuid IN (SELECT item_uuid FROM materialized_containers WHERE state_source = 'system') AND item_uuid NOT IN (SELECT item_uuid FROM materialized_containers WHERE is_materialized = 1)")
                    try execute("UPDATE item_local_state SET materialized = 1, system_visible = 1, updated_at = unixepoch() WHERE item_uuid IN (SELECT item_uuid FROM materialized_containers WHERE is_materialized = 1)")
                }
                try execute("UPDATE system_set_state SET current_generation = \(complete ? String(claim.generation) : "current_generation"), active_generation = \(complete ? "NULL" : String(claim.generation)), active_owner = NULL, active_started_at = NULL, scan_state = '\(complete ? "idle" : "failed")', refresh_required = \(complete ? 0 : 1), refresh_cursor = \(cursor.map { "X'\($0.hexString)'" } ?? "NULL"), maximum_size_reached = 0, system_anchor = \(anchor.map { "X'\($0.hexString)'" } ?? "system_anchor"), last_completed_at = \(complete ? "unixepoch()" : "last_completed_at"), updated_at = unixepoch() WHERE set_kind = '\(sql(claim.setKind))' AND active_generation = \(claim.generation) AND active_owner = '\(claim.ownerID.uuidString)'\(domainClause)")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func publishPendingSet(claim: SystemSetClaim, complete: Bool, capped: Bool, anchor: Data? = nil, cursor: Data? = nil) throws {
        try withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                let domainClause = claim.domainVersion.map { " AND domain_version = X'\($0.hexString)'" } ?? ""
                guard try scalar("SELECT active_generation FROM system_set_state WHERE set_kind = '\(sql(claim.setKind))' AND active_owner = '\(claim.ownerID.uuidString)'\(domainClause) LIMIT 1") == String(claim.generation) else { throw StoreBridgeError.generationFenced }
                if complete {
                    try bumpWorkingSetRevisionUnlocked()
                    try execute("UPDATE system_pending_observations SET is_pending = 1, published_payload = observed_payload WHERE observed_generation = \(claim.generation)")
                }
                if complete && !capped {
                    try execute("UPDATE system_pending_observations SET is_pending = 0, published_payload = NULL WHERE observed_generation IS NULL OR observed_generation != \(claim.generation)")
                    try execute("UPDATE item_local_state SET upload_state = 'none', upload_error = NULL, updated_at = unixepoch() WHERE item_uuid IN (SELECT item_uuid FROM system_pending_observations WHERE is_pending = 0) AND NOT EXISTS (SELECT 1 FROM pending_items WHERE pending_items.item_uuid = item_local_state.item_uuid) AND NOT EXISTS (SELECT 1 FROM operations WHERE operations.item_uuid = item_local_state.item_uuid AND operations.state NOT IN ('committed', 'cancelled', 'permanently_failed', 'resolved'))")
                }
                try execute("UPDATE system_set_state SET current_generation = \(complete ? String(claim.generation) : "current_generation"), active_generation = \(complete ? "NULL" : String(claim.generation)), active_owner = NULL, active_started_at = NULL, scan_state = '\(complete ? "idle" : "failed")', refresh_required = \(complete ? 0 : 1), refresh_cursor = \(cursor.map { "X'\($0.hexString)'" } ?? "NULL"), maximum_size_reached = \(capped ? 1 : 0), system_anchor = \(anchor.map { "X'\($0.hexString)'" } ?? "system_anchor"), last_completed_at = \(complete ? "unixepoch()" : "last_completed_at"), updated_at = unixepoch() WHERE set_kind = '\(sql(claim.setKind))' AND active_generation = \(claim.generation) AND active_owner = '\(claim.ownerID.uuidString)'\(domainClause)")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func isSystemPending(_ identifier: String) throws -> Bool {
        try withLock {
            (try scalar("SELECT is_pending FROM system_pending_observations WHERE item_uuid = '\(sql(identifier))' LIMIT 1") ?? "0") == "1"
        }
    }

    func beginProjectionRefresh(domainIdentifier: String, targetRevision: UInt64 = ProjectionSchema.currentRevision, scope: String = "working_set", fallbackEnabled: Bool = false, jobID: UUID = UUID()) throws -> ProjectionRefreshJob {
        try withLock {
            try execute("INSERT OR REPLACE INTO projection_refresh_jobs (job_id, domain_id, target_revision, scope, cursor, state, attempt, last_error, feature_fallback_enabled, updated_at) VALUES ('\(jobID.uuidString)', '\(sql(domainIdentifier))', \(targetRevision), '\(sql(scope))', NULL, 'active', 0, NULL, \(fallbackEnabled ? 1 : 0), unixepoch())")
            return ProjectionRefreshJob(jobID: jobID, domainIdentifier: domainIdentifier, targetRevision: targetRevision, scope: scope, cursor: nil, state: "active", attempt: 0, lastError: nil, fallbackEnabled: fallbackEnabled)
        }
    }

    func projectionRefreshJob(jobID: UUID) throws -> ProjectionRefreshJob? {
        try withLock {
            let statement = try prepare("SELECT job_id, domain_id, target_revision, scope, cursor, state, attempt, last_error, feature_fallback_enabled FROM projection_refresh_jobs WHERE job_id = '\(jobID.uuidString)' LIMIT 1")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let id = UUID(uuidString: columnString(statement, 0) ?? "") else { return nil }
            return ProjectionRefreshJob(jobID: id, domainIdentifier: columnString(statement, 1) ?? "", targetRevision: UInt64(max(0, sqlite3_column_int64(statement, 2))), scope: columnString(statement, 3) ?? "working_set", cursor: columnString(statement, 4), state: columnString(statement, 5) ?? "active", attempt: Int(sqlite3_column_int(statement, 6)), lastError: columnString(statement, 7), fallbackEnabled: sqlite3_column_int(statement, 8) != 0)
        }
    }

    func advanceProjectionRefresh(jobID: UUID, cursor: String?, state: String = "active", error: String? = nil) throws {
        try withLock {
            try execute("UPDATE projection_refresh_jobs SET cursor = \(nullable(cursor)), state = '\(sql(state))', attempt = attempt + 1, last_error = \(nullable(error)), updated_at = unixepoch() WHERE job_id = '\(jobID.uuidString)'")
        }
    }

    /// Commits one bounded projection-refresh page and its durable cursor in
    /// the same transaction. If the process dies, the next worker either sees
    /// neither the page nor its cursor, or sees both and resumes after it.
    func commitProjectionRefreshPage(jobID: UUID, items: [RemoteItem], cursor: String?) throws {
        guard !items.isEmpty else {
            try advanceProjectionRefresh(jobID: jobID, cursor: cursor, state: "active")
            return
        }
        try withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                guard let state = try scalar("SELECT state FROM projection_refresh_jobs WHERE job_id = '\(jobID.uuidString)' LIMIT 1"),
                      state == "active" || state == "failed" else {
                    throw StoreBridgeError.generationFenced
                }
                for item in items {
                    try insertItemUnlocked(item)
                    let payload = try encodeJournalPayload(item)
                    _ = try appendProviderChangeUnlocked(
                        itemIdentifier: item.itemIdentifier,
                        oldParentIdentifier: item.parentIdentifier,
                        newParentIdentifier: item.parentIdentifier,
                        kind: "projection_refresh",
                        version: item.version.content,
                        origin: "projection_refresh",
                        itemPayload: payload,
                        itemVersion: item.version
                    )
                }
                try execute("UPDATE projection_refresh_jobs SET cursor = \(nullable(cursor)), state = 'active', attempt = attempt + 1, last_error = NULL, updated_at = unixepoch() WHERE job_id = '\(jobID.uuidString)'")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func completeProjectionRefresh(jobID: UUID) throws {
        try withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                guard let job = try projectionRefreshJobUnlocked(jobID: jobID) else { throw StoreBridgeError.unknownDomain }
                try execute("UPDATE projection_refresh_jobs SET state = 'completed', updated_at = unixepoch() WHERE job_id = '\(jobID.uuidString)'")
                try execute("UPDATE sync_state SET last_applied_projection_schema_revision = \(job.targetRevision), projection_schema_revision = MAX(projection_schema_revision, \(job.targetRevision)) WHERE singleton = 1")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func setViewExcluded(identifier: String, excluded: Bool) throws {
        try withLock {
            var state = try localStateUnlocked(identifier: identifier)
            state.viewExcluded = excluded
            try invalidateDirectorySnapshotsUnlocked()
            try upsertLocalStateUnlocked(identifier: identifier, state: state)
        }
    }

    func setKeepDownloadedPolicy(identifier: String, policy: KeepDownloadedPolicy) throws {
        try withLock {
            var state = try localStateUnlocked(identifier: identifier)
            state.keepPolicy = policy
            try upsertLocalStateUnlocked(identifier: identifier, state: state)
        }
    }

    @discardableResult
    func setKeepDownloadedPolicyAndJournal(identifier: String, policy: KeepDownloadedPolicy, origin: String = "local_action") throws -> JournalChange? {
        try withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                var state = try localStateUnlocked(identifier: identifier)
                guard state.keepPolicy != policy else {
                    try execute("COMMIT")
                    return nil
                }
                state.keepPolicy = policy
                try upsertLocalStateUnlocked(identifier: identifier, state: state)
                guard let item = try itemUnlockedForProjection(identifier: identifier) else {
                    try execute("COMMIT")
                    return nil
                }
                let payload = try encodeJournalPayload(item)
                let change = try appendProviderChangeUnlocked(itemIdentifier: item.itemIdentifier, oldParentIdentifier: item.parentIdentifier, newParentIdentifier: item.parentIdentifier, kind: "keep_policy_changed", version: item.version.content, origin: origin, itemPayload: payload, itemVersion: item.version)
                try execute("COMMIT")
                return change
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func effectiveKeepDownloadedPolicy(identifier: String) throws -> KeepDownloadedPolicy {
        try withLock { try effectiveKeepDownloadedPolicyUnlocked(identifier: identifier) }
    }

    func setProjectionSchemaRevision(_ revision: UInt64) throws {
        try withLock { try execute("UPDATE sync_state SET projection_schema_revision = MAX(projection_schema_revision, \(revision)) WHERE singleton = 1") }
    }

    func hasExclusionCandidate(itemIdentifier: String?, systemItemIdentifier: String?) throws -> Bool {
        try withLock {
            let itemClause = itemIdentifier.map { "item_uuid = '\(sql($0))'" } ?? "item_uuid IS NULL"
            let systemClause = systemItemIdentifier.map { "system_item_identifier = '\(sql($0))'" } ?? "system_item_identifier IS NULL"
            return (try scalar("SELECT 1 FROM exclusion_intents WHERE \(itemClause) AND \(systemClause) AND state IN ('active', 'consumed') LIMIT 1") ?? "0") == "1"
        }
    }

    func consumeExclusionIntent(itemIdentifier: String?, systemItemIdentifier: String?, kind: ExclusionIntent.Kind, expectedVersion: Data?, pathHash: Data?, ruleRevision: UInt64? = nil, sourceGeneration: UInt64? = nil, now: Date = Date()) throws -> Bool {
        try withLock {
            let itemClause = itemIdentifier.map { "item_uuid = '\(sql($0))'" } ?? "item_uuid IS NULL"
            let systemClause = systemItemIdentifier.map { "system_item_identifier = '\(sql($0))'" } ?? "system_item_identifier IS NULL"
            let versionClause = expectedVersion.map { "AND (expected_version IS NULL OR expected_version = X'\($0.hexString)')" } ?? ""
            let pathClause = pathHash.map { "AND (path_hash IS NULL OR path_hash = X'\($0.hexString)')" } ?? ""
            let revisionClause = ruleRevision.map { "AND rule_revision = \($0)" } ?? ""
            let generationClause = sourceGeneration.map { "AND source_generation = \($0)" } ?? ""
            let query = "SELECT intent_id FROM exclusion_intents WHERE \(itemClause) AND \(systemClause) AND kind = '\(kind.rawValue)' \(revisionClause) \(generationClause) \(versionClause) \(pathClause) AND state = 'active' AND (expires_at IS NULL OR expires_at >= \(Int64(now.timeIntervalSince1970))) LIMIT 1"
            guard let id = try scalar(query) else { return false }
            try execute("UPDATE exclusion_intents SET state = 'consumed', consumed_at = unixepoch() WHERE intent_id = '\(sql(id))' AND state = 'active'")
            return true
        }
    }

    func hasPendingWork(itemIdentifier: String) throws -> Bool {
        try withLock {
            let sqlIdentifier = sql(itemIdentifier)
            let count = try scalar("SELECT (SELECT COUNT(*) FROM pending_items WHERE item_uuid = '\(sqlIdentifier)') + (SELECT COUNT(*) FROM operations WHERE item_uuid = '\(sqlIdentifier)' AND state NOT IN ('committed', 'cancelled', 'permanently_failed', 'resolved')) + (SELECT COUNT(*) FROM conflicts WHERE item_uuid = '\(sqlIdentifier)' AND state = 'pending')")
            return (Int(count ?? "0") ?? 0) > 0
        }
    }

    private func localStateUnlocked(identifier: String) throws -> ItemLocalState {
        let statement = try prepare("SELECT materialized, visited, keep_policy, upload_state, download_state, upload_error, download_error, system_visible, view_excluded, last_used_at FROM item_local_state WHERE item_uuid = '\(sql(identifier))' LIMIT 1")
        var state = ItemLocalState()
        if sqlite3_step(statement) == SQLITE_ROW {
            state = ItemLocalState(
                materialized: sqlite3_column_int(statement, 0) != 0,
                visited: sqlite3_column_int(statement, 1) != 0,
                keepPolicy: KeepDownloadedPolicy(rawValue: columnString(statement, 2) ?? "inherit") ?? .inherit,
                uploadState: LocalTransferState(rawValue: columnString(statement, 3) ?? "none") ?? .none,
                downloadState: LocalTransferState(rawValue: columnString(statement, 4) ?? "none") ?? .none,
                uploadError: columnString(statement, 5),
                downloadError: columnString(statement, 6),
                systemVisible: sqlite3_column_int(statement, 7) != 0,
                viewExcluded: sqlite3_column_int(statement, 8) != 0,
                lastUsedAt: sqlite3_column_type(statement, 9) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 9)))
            )
        }
        sqlite3_finalize(statement)
        if let pending = try scalar("SELECT upload_error FROM pending_items WHERE item_uuid = '\(sql(identifier))' LIMIT 1") {
            state.uploadState = state.uploadState == .none ? .queued : state.uploadState
            state.uploadError = pending
        }
        if let pendingDownload = try scalar("SELECT download_error FROM pending_items WHERE item_uuid = '\(sql(identifier))' LIMIT 1") {
            state.downloadState = state.downloadState == .none ? .queued : state.downloadState
            state.downloadError = pendingDownload
        }
        if (try scalar("SELECT is_pending FROM system_pending_observations WHERE item_uuid = '\(sql(identifier))' LIMIT 1") ?? "0") == "1", state.uploadState == .none {
            state.uploadState = .queued
        }
        return state
    }

    private func exclusionRulesUnlocked(domainIdentifier: String) throws -> ExclusionRuleSnapshot? {
        guard let encoded = try scalar("SELECT value FROM preferences WHERE key = 'exclusion.rules.\(sql(domainIdentifier))' LIMIT 1") else { return nil }
        guard let data = encoded.data(using: .utf8), let rules = try? JSONDecoder().decode(ExclusionRuleSnapshot.self, from: data) else {
            throw StoreBridgeError.corrupted
        }
        return rules
    }

    private func invalidateDirectorySnapshotsUnlocked() throws {
        try execute("DELETE FROM directory_snapshot_heads")
        try execute("DELETE FROM directory_snapshot_generations")
        try execute("DELETE FROM directory_snapshots")
    }

    private func isExcludedByCurrentRulesUnlocked(item: RemoteItem, domainIdentifier: String) throws -> Bool {
        guard let rules = try exclusionRulesUnlocked(domainIdentifier: domainIdentifier) else { return false }
        let rootURI = try scalar("SELECT root_uri FROM domains WHERE domain_id = '\(sql(domainIdentifier))' LIMIT 1") ?? "/"
        let relative = CloudreveRemoteURI.relativePath(item.uri, root: rootURI) ?? item.name
        return rules.matches(relativePath: relative, isRoot: item.itemIdentifier == NSFileProviderItemIdentifier.rootContainer.rawValue)
    }

    private func itemUnlockedForProjection(identifier: String) throws -> RemoteItem? {
        let statement = try prepare("SELECT item_uuid, remote_entity_id, parent_uuid, trash_original_parent_uuid, remote_name, kind, current_remote_uri, size, remote_version, content_version, metadata_version, trashed, tombstone, created_at, modified_at, can_read, can_write, can_add_children, can_trash, can_delete, content_type FROM items WHERE item_uuid = '\(sql(identifier))' LIMIT 1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return itemFromStatement(statement)
    }

    private func upsertLocalStateUnlocked(identifier: String, state: ItemLocalState) throws {
        try execute("""
        INSERT INTO item_local_state (item_uuid, materialized, visited, keep_policy, upload_state, download_state, upload_error, download_error, system_visible, view_excluded, last_used_at, updated_at)
        VALUES ('\(sql(identifier))', \(state.materialized ? 1 : 0), \(state.visited ? 1 : 0), '\(state.keepPolicy.rawValue)', '\(state.uploadState.rawValue)', '\(state.downloadState.rawValue)', \(nullable(state.uploadError)), \(nullable(state.downloadError)), \(state.systemVisible ? 1 : 0), \(state.viewExcluded ? 1 : 0), \(state.lastUsedAt.map { String(Int64($0.timeIntervalSince1970)) } ?? "NULL"), unixepoch())
        ON CONFLICT(item_uuid) DO UPDATE SET materialized = excluded.materialized, visited = excluded.visited, keep_policy = excluded.keep_policy, upload_state = excluded.upload_state, download_state = excluded.download_state, upload_error = excluded.upload_error, download_error = excluded.download_error, system_visible = excluded.system_visible, view_excluded = excluded.view_excluded, last_used_at = excluded.last_used_at, updated_at = unixepoch()
        """)
    }

    private func effectiveKeepDownloadedPolicyUnlocked(identifier: String) throws -> KeepDownloadedPolicy {
        var current = identifier
        var visited = Set<String>()
        for _ in 0..<256 {
            guard visited.insert(current).inserted else { return .automatic }
            let state = try localStateUnlocked(identifier: current)
            if state.keepPolicy != .inherit { return state.keepPolicy }
            guard let parent = try scalar("SELECT parent_uuid FROM items WHERE item_uuid = '\(sql(current))' LIMIT 1"), !parent.isEmpty else { return .automatic }
            current = parent
        }
        return .automatic
    }

    private func metadataMoveAllowedUnlocked() throws -> Bool {
        guard let encoded = try scalar("SELECT capability_snapshot FROM domains ORDER BY domain_id LIMIT 1"), let data = encoded.data(using: .utf8), let snapshot = try? JSONDecoder().decode(CapabilitySnapshot.self, from: data) else {
            return false
        }
        return snapshot.stableItemIdentity == .verified && snapshot.stableRootIdentity == .verified && snapshot.conditionalMetadataMutation == .verified && snapshot.operations.metadataMove == .verified
    }

    private func snapshotDescriptorUnlocked(snapshotID: String) throws -> DirectorySnapshotDescriptor {
        let statement = try prepare("SELECT snapshot_id, domain_id, parent_uuid, generation, expires_at, state, next_cursor FROM directory_snapshot_generations WHERE snapshot_id = '\(sql(snapshotID))' LIMIT 1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreBridgeError.snapshotExpired }
        return DirectorySnapshotDescriptor(snapshotID: columnString(statement, 0) ?? snapshotID, domainIdentifier: columnString(statement, 1) ?? "", parentIdentifier: columnString(statement, 2) ?? "", generation: UInt64(max(0, sqlite3_column_int64(statement, 3))), expiresAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 4))), state: columnString(statement, 5) ?? "failed", nextCursor: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : columnBlob(statement, 6))
    }

    private func completeSnapshotDescriptorUnlocked(parentIdentifier: String, domainIdentifier: String? = nil) throws -> DirectorySnapshotDescriptor? {
        let domainClause = domainIdentifier.map { " AND domain_id = '\(sql($0))'" } ?? ""
        let statement = try prepare("SELECT current_snapshot_id FROM directory_snapshot_heads WHERE parent_uuid = '\(sql(parentIdentifier))'\(domainClause) LIMIT 1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let snapshotID = columnString(statement, 0) else { return nil }
        return try snapshotDescriptorUnlocked(snapshotID: snapshotID)
    }

    private func projectionRefreshJobUnlocked(jobID: UUID) throws -> ProjectionRefreshJob? {
        let statement = try prepare("SELECT job_id, domain_id, target_revision, scope, cursor, state, attempt, last_error, feature_fallback_enabled FROM projection_refresh_jobs WHERE job_id = '\(jobID.uuidString)' LIMIT 1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let id = UUID(uuidString: columnString(statement, 0) ?? "") else { return nil }
        return ProjectionRefreshJob(jobID: id, domainIdentifier: columnString(statement, 1) ?? "", targetRevision: UInt64(max(0, sqlite3_column_int64(statement, 2))), scope: columnString(statement, 3) ?? "working_set", cursor: columnString(statement, 4), state: columnString(statement, 5) ?? "active", attempt: Int(sqlite3_column_int(statement, 6)), lastError: columnString(statement, 7), fallbackEnabled: sqlite3_column_int(statement, 8) != 0)
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
