import Foundation
import FileProvider
import ServiceManagement
import OSLog
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveAuthKit
import CloudreveObservability

public enum EventEnrichmentError: Error, Equatable {
    case malformedHint
    case outsideScope
    case unavailable
    /// The event names a file an upload session has only just created: nothing to apply until
    /// the upload completes, which raises its own event.
    case pendingUpload
}

public struct EventScopeGuard: Sendable {
    public let rootRemoteID: String
    public let rootURI: String
    public private(set) var rejectedCount: Int

    public init(rootRemoteID: String, rootURI: String) { self.rootRemoteID = rootRemoteID; self.rootURI = rootURI; self.rejectedCount = 0 }

    public mutating func accepts(remoteID: String?, fromURI: String?, toURI: String?) -> Bool {
        guard let remoteID, !remoteID.isEmpty, remoteID != rootRemoteID, !remoteID.contains(where: { $0.isWhitespace || $0 == "\0" }) else { rejectedCount += 1; return false }
        let normalizedRoot = canonicalURI(rootURI)
        guard normalizedRoot != nil else { rejectedCount += 1; return false }
        // Cloudreve sends an empty `to` for create/modify/delete events; only
        // a supplied path is evidence that the event crosses this scope.
        for uri in [fromURI, toURI].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            guard let normalized = canonicalURI(uri), let normalizedRoot else { rejectedCount += 1; return false }
            if normalizedRoot != "/" && normalized != normalizedRoot && !normalized.hasPrefix(normalizedRoot + "/") {
                rejectedCount += 1
                return false
            }
        }
        return true
    }
}

private func canonicalURI(_ value: String) -> String? {
    if value.hasPrefix("cloudreve://"), let components = URLComponents(string: value), let host = components.host, let path = CloudreveRemoteURI.path(value) {
        let user = components.user.map { "\($0)@" } ?? ""
        return "cloudreve://\(user)\(host.lowercased())\(path == "/" ? "" : path)"
    }
    let normalized = value.replacingOccurrences(of: "\\", with: "/")
    guard normalized.hasPrefix("/"), !normalized.contains("\0") else { return nil }
    var parts: [Substring] = []
    for part in normalized.split(separator: "/") {
        guard part != ".", part != ".." else { return nil }
        parts.append(part)
    }
    return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
}

private func canonicalURI(_ value: String, accountID: String) -> String? {
    try? CloudreveRemoteURI.canonical(value, accountID: accountID)
}

public struct RemoteEventPayload: Codable, Sendable, Equatable {
    public let type: String?
    public let id: String?
    public let from: String?
    public let to: String?
    public init(type: String?, id: String?, from: String?, to: String?) { self.type = type; self.id = id; self.from = from; self.to = to }

    private enum CodingKeys: String, CodingKey { case type; case id; case fileID = "file_id"; case from; case to }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        let directID = try container.decodeIfPresent(String.self, forKey: .id)
        let fileID = try container.decodeIfPresent(String.self, forKey: .fileID)
        id = directID ?? fileID
        from = try container.decodeIfPresent(String.self, forKey: .from)
        to = try container.decodeIfPresent(String.self, forKey: .to)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(from, forKey: .from)
        try container.encodeIfPresent(to, forKey: .to)
    }
}

private struct EventAPIEnvelope<Value: Decodable>: Decodable {
    let code: Int
    let data: Value?
}

private struct EventFileDTO: Decodable {
    let type: Int
    let id: String
    let name: String
    let size: Int64?
    let path: String
    let permission: String?
    let capability: String?
    let updatedAt: String?
    let createdAt: String?
    let primaryEntity: String?
    let metadata: CloudreveFileMetadata?

    var fields: CloudreveFileFields {
        CloudreveFileFields(type: type, id: id, name: name, size: size, permission: permission, capability: capability, createdAt: createdAt, updatedAt: updatedAt, primaryEntity: primaryEntity, metadata: metadata?.values ?? [:])
    }

    enum CodingKeys: String, CodingKey {
        case type; case id; case name; case size; case path; case permission; case capability
        case updatedAt = "updated_at"; case createdAt = "created_at"; case primaryEntity = "primary_entity"; case metadata
    }
}

private func parseEventDate(_ value: String?) -> Date? {
    CloudreveItemMapper.parseDate(value)
}

/// Enriches Cloudreve's small `type/file_id/from/to` hint through the
/// authenticated `file/info` endpoint before touching local state.
public final class CloudreveEventEnricher: RemoteEventEnricher, @unchecked Sendable {
    private let origin: URL
    private let rootRemoteID: String
    private let rootURI: String
    private let store: SQLiteStateStore
    private let vault: CredentialVault
    private let credentialReference: String
    private let capabilitySnapshot: CapabilitySnapshot
    private let session: URLSession
    private let credentialRefresh: CredentialRefreshService
    private let logger = Logger(subsystem: "ai.tiy.nimbussync", category: "remote-events")

    /// `credentialRefresh` defaults to the App Group-locked shared service; tests inject one
    /// without the cross-process lock.
    public init(origin: URL, rootURI: String, rootRemoteID: String = "", store: SQLiteStateStore, vault: CredentialVault, credentialReference: String, capabilitySnapshot: CapabilitySnapshot = CapabilitySnapshot(), session: URLSession? = nil, credentialRefresh: CredentialRefreshService? = nil) {
        self.origin = origin; self.rootRemoteID = rootRemoteID; self.rootURI = rootURI; self.store = store; self.vault = vault; self.credentialReference = credentialReference; self.capabilitySnapshot = capabilitySnapshot
        self.credentialRefresh = credentialRefresh ?? CredentialRefreshService(vault: vault, session: session)
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: configuration, delegate: EventRedirectPolicy(), delegateQueue: nil)
        }
    }

    public func enrich(_ hint: RemoteEventHint) async throws -> EnrichedRemoteChange? {
        guard let remoteID = hint.remoteID, !remoteID.isEmpty else { throw EventEnrichmentError.malformedHint }
        guard let file = try await fetchFile(id: remoteID) else { return nil }
        let existingIdentifier = try store.itemIdentifier(forRemoteID: remoteID)
        if existingIdentifier == nil, file.fields.hasActiveUploadSession { throw EventEnrichmentError.pendingUpload }
        guard let normalizedPath = canonicalURI(file.path, accountID: URLComponents(string: rootURI)?.user ?? ""),
              file.id != rootRemoteID,
              CloudreveRemoteURI.isWithin(normalizedPath, root: rootURI) else {
            throw EventEnrichmentError.outsideScope
        }
        let parentIdentifier = try await parentIdentifier(for: normalizedPath, existingIdentifier: existingIdentifier)
        let item = CloudreveItemMapper.item(from: file.fields, normalizedURI: normalizedPath, parentIdentifier: parentIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue, itemIdentifier: existingIdentifier ?? CloudreveIdentifier.item(), capabilities: capabilitySnapshot)
        return EnrichedRemoteChange(item: item, oldParentIdentifier: existingIdentifier.flatMap { try? store.item(identifier: $0)?.parentIdentifier }, newParentIdentifier: parentIdentifier, kind: hint.kind.rawValue)
    }

    private func fetchFile(id: String) async throws -> EventFileDTO? {
        var components = URLComponents(url: origin.appendingPathComponent("api/v4/file/info"), resolvingAgainstBaseURL: false)
        components?.setCloudreveQueryItems([URLQueryItem(name: "id", value: id), URLQueryItem(name: "extended", value: "true")])
        guard let url = components?.url else { throw CoreFailure(code: .network, retryable: true) }
        logger.info("event_enrichment.request.begin endpoint=file/info")
        let credential = try await credentialRefresh.credential(origin: origin, reference: credentialReference)
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EventEnrichmentError.unavailable }
        logger.info("event_enrichment.request.response endpoint=file/info status=\(http.statusCode, privacy: .public)")
        if http.statusCode == 404 { return nil }
        if http.statusCode == 401 { throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true) }
        guard (200..<300).contains(http.statusCode) else { throw EventEnrichmentError.unavailable }
        let envelope = try JSONDecoder().decode(EventAPIEnvelope<EventFileDTO>.self, from: data)
        guard envelope.code == 0 else { return nil }
        return envelope.data
    }

    private func fetchFile(uri: String) async throws -> EventFileDTO? {
        var components = URLComponents(url: origin.appendingPathComponent("api/v4/file/info"), resolvingAgainstBaseURL: false)
        components?.setCloudreveQueryItems([URLQueryItem(name: "uri", value: uri), URLQueryItem(name: "extended", value: "true")])
        guard let url = components?.url else { throw CoreFailure(code: .network, retryable: true) }
        let credential = try await credentialRefresh.credential(origin: origin, reference: credentialReference)
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EventEnrichmentError.unavailable }
        if http.statusCode == 404 { return nil }
        if http.statusCode == 401 { throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true) }
        guard (200..<300).contains(http.statusCode) else { throw EventEnrichmentError.unavailable }
        let envelope = try JSONDecoder().decode(EventAPIEnvelope<EventFileDTO>.self, from: data)
        guard envelope.code == 0 else { return nil }
        return envelope.data
    }

    private func parentIdentifier(for path: String, existingIdentifier: String?) async throws -> String? {
        guard let parentURI = CloudreveRemoteURI.parent(path), let rootURI = canonicalURI(rootURI) else { throw EventEnrichmentError.unavailable }
        if parentURI == rootURI { return NSFileProviderItemIdentifier.rootContainer.rawValue }
        _ = existingIdentifier
        return try await hydrateParent(uri: parentURI, rootURI: rootURI, depth: 0)
    }

    private func hydrateParent(uri: String, rootURI: String, depth: Int) async throws -> String? {
        guard depth < 32, CloudreveRemoteURI.isWithin(uri, root: rootURI) else { throw EventEnrichmentError.outsideScope }
        if let parentIdentifier = try store.itemIdentifier(forRemoteURI: uri) { return parentIdentifier }
        guard let file = try await fetchFile(uri: uri), file.type == 1 else { throw EventEnrichmentError.unavailable }
        let parentIdentifier: String
        if let ancestorURI = CloudreveRemoteURI.parent(uri), ancestorURI != rootURI {
            guard let ancestorIdentifier = try await hydrateParent(uri: ancestorURI, rootURI: rootURI, depth: depth + 1) else { throw EventEnrichmentError.unavailable }
            parentIdentifier = ancestorIdentifier
        } else {
            parentIdentifier = NSFileProviderItemIdentifier.rootContainer.rawValue
        }
        guard file.id != rootRemoteID else { throw EventEnrichmentError.outsideScope }
        let identifier = try store.itemIdentifier(forRemoteID: file.id) ?? CloudreveIdentifier.item()
        let normalized = try CloudreveRemoteURI.canonical(file.path, accountID: URLComponents(string: rootURI)?.user ?? "")
        guard CloudreveRemoteURI.isWithin(normalized, root: rootURI) else { throw EventEnrichmentError.outsideScope }
        let item = CloudreveItemMapper.item(from: file.fields, normalizedURI: normalized, parentIdentifier: parentIdentifier, itemIdentifier: identifier, capabilities: capabilitySnapshot)
        try store.insertItem(item)
        return identifier
    }
}

private final class EventRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let current = task.currentRequest?.url
        let next = request.url
        guard current?.scheme == next?.scheme, current?.host == next?.host, current?.port == next?.port else { completionHandler(nil); return }
        completionHandler(request)
    }
}

private struct ReconcilePagination: Decodable {
    let page: Int?
    let pageSize: Int?
    let totalItems: Int64?
    let nextToken: String?
    enum CodingKeys: String, CodingKey { case page; case pageSize = "page_size"; case totalItems = "total_items"; case nextToken = "next_token" }
}

private struct ReconcileListDTO: Decodable { let files: [EventFileDTO]; let pagination: ReconcilePagination? }

private func reconciliationPaginationIsVerified(_ snapshot: CapabilitySnapshot, usesCursor: Bool) -> Bool {
    snapshot.completePagination == .verified &&
        snapshot.snapshotSafePagination == .verified &&
        (!usesCursor || snapshot.cursorPagination == .verified)
}

private struct ReconcileWork: Codable {
    let uri: String
    let parent: String
}

private struct ReconcileCursor: Codable {
    let queue: [ReconcileWork]
    let current: ReconcileWork?
    let page: Int
    let token: String?
    let usedTokens: [String]
    /// Items checked up to this point, so a resumed check keeps counting instead of starting
    /// over at zero. Absent in cursors written before it existed.
    var scanned: Int? = nil
}

/// Performs a bounded, resumable normal-tree scan for a Domain. It never
/// creates tombstones when trash coverage is unavailable; missing-item
/// deletion remains fail-closed until a verified trash contract exists.
public final class CloudreveReconciliationService: @unchecked Sendable {
    private let origin: URL
    private let store: SQLiteStateStore
    private let registry: SQLiteStateStore?
    private let vault: CredentialVault
    private let credentialReference: String
    private let session: URLSession
    private let credentialRefresh: CredentialRefreshService
    private let logger = Logger(subsystem: "ai.tiy.nimbussync", category: "reconciliation")

    public init(origin: URL, store: SQLiteStateStore, registry: SQLiteStateStore? = nil, vault: CredentialVault, credentialReference: String, session: URLSession? = nil, credentialRefresh: CredentialRefreshService? = nil) {
        self.origin = origin; self.store = store; self.registry = registry; self.vault = vault; self.credentialReference = credentialReference
        self.credentialRefresh = credentialRefresh ?? CredentialRefreshService(vault: vault, session: session)
        if let session { self.session = session }
        else { self.session = URLSession(configuration: .ephemeral, delegate: EventRedirectPolicy(), delegateQueue: nil) }
    }

    public func reconcile(descriptor: DomainDescriptor, reason: String = "unspecified") async throws {
        let correlationID = UUID().uuidString.lowercased()
        logger.info("reconcile.started id=\(correlationID, privacy: .public) domain=\(descriptor.identifier, privacy: .public) reason=\(reason, privacy: .public)")
        let activeRun = try store.activeReconcileRuns().first(where: { $0.scope == descriptor.currentRootURI })
        let runID = activeRun?.id ?? UUID()
        var savedCursor = activeRun?.cursor.flatMap { try? JSONDecoder().decode(ReconcileCursor.self, from: Data($0.utf8)) }
        if savedCursor?.current == nil && savedCursor?.queue.isEmpty == true { savedCursor = nil }
        if let savedCursor {
            ActivityLog.shared.info("sync", "Full check resumed · reason=\(reason) · \(savedCursor.scanned ?? 0) items already checked")
        } else {
            ActivityLog.shared.info("sync", "Full check started · reason=\(reason)")
        }
        // A resumed cursor does not carry a complete proof of every item
        // observed before the previous process stopped. Finish the scan and
        // leave deletion for the next fresh generation instead of risking a
        // tombstone for an item that was already seen in the earlier prefix.
        var deletionSafe = savedCursor == nil
        if activeRun == nil {
            try store.startReconcile(runID: runID, scope: descriptor.currentRootURI, generation: UInt64(Date().timeIntervalSince1970), phase: "prepared", cursor: nil)
        } else {
            try store.markReconcileAttempt(runID: runID, scannedItems: savedCursor?.scanned ?? 0)
        }
        // The newest resumable position. Written to the store at most every few seconds; the
        // exact one is written when the check fails, so a retry resumes where this one stopped.
        var latestCursor: ReconcileCursor?
        var knownRemoteIDs = Set<String>()
        try store.updateSyncState(reconcileStatus: "scanning_normal")
        do {
            let root = try await fetchFile(id: descriptor.rootRemoteID)
        guard root.id == descriptor.rootRemoteID, root.type == 1 else { throw CoreFailure(code: .rootUnavailable, retryable: false, userActionRequired: true) }
        let rootPath = try CloudreveRemoteURI.canonical(root.path, accountID: descriptor.accountID)
        let rootScope = try RemoteScope(origin: descriptor.scope.origin, accountID: descriptor.accountID, rootURI: rootPath)
        if rootScope.rootURI != descriptor.currentRootURI {
            savedCursor = nil
            deletionSafe = true
            if let registry, try registry.allDomains().contains(where: { stored in
                guard stored.identifier != descriptor.identifier, let otherScope = try? RemoteScope(origin: stored.origin, accountID: stored.accountID, rootURI: stored.rootURI) else { return false }
                return otherScope.overlaps(rootScope)
            }) {
                throw CoreFailure(code: .scopeConflict, retryable: false, userActionRequired: true)
            }
            try store.updateDomainRootURI(identifier: descriptor.identifier, rootURI: rootScope.rootURI)
            try registry?.updateDomainRootURI(identifier: descriptor.identifier, rootURI: rootScope.rootURI)
        }
        // A root move changes the local view; rows from the previous scope
        // must never be interpreted as remote deletions during this scan.
        knownRemoteIDs = Set(try store.remoteIdentities().compactMap { identity in
            CloudreveRemoteURI.isWithin(identity.uri, root: rootScope.rootURI) ? identity.remoteID : nil
        })
        var queue: [ReconcileWork] = savedCursor?.queue ?? [ReconcileWork(uri: rootScope.rootURI, parent: NSFileProviderItemIdentifier.rootContainer.rawValue)]
        var currentWork = savedCursor?.current
        var page = savedCursor?.page ?? 1
        var token = savedCursor?.token
        var usedTokens = Set(savedCursor?.usedTokens ?? [])
        var seen = Set<String>([descriptor.rootRemoteID])
        // The previous check's item count is the estimate of how many this one will see.
        let expectedItems = knownRemoteIDs.count
        let resumedCount = savedCursor?.scanned ?? 0
        func scanProgress() -> (scanned: Int, expected: Int) { (resumedCount + seen.count - 1, expectedItems) }
        var lastCursorWrite = Date.distantPast
        /// Records the resumable position. Writing the whole folder queue after every page made
        /// large Domains slow, and the former 64 KiB cap threw the position away instead, so
        /// every restart began again at the root. Rescanning a few folders after a resume is
        /// harmless: every step is an idempotent upsert.
        func saveCursor(queue: [ReconcileWork], current: ReconcileWork?, page: Int, token: String?, usedTokens: Set<String>, force: Bool = false) throws {
            var cursor = ReconcileCursor(queue: queue, current: current, page: page, token: token, usedTokens: usedTokens.sorted())
            cursor.scanned = scanProgress().scanned
            latestCursor = cursor
            if force || Date().timeIntervalSince(lastCursorWrite) >= Self.cursorWriteInterval {
                try persistCursor(runID: runID, cursor: cursor, progress: scanProgress())
                lastCursorWrite = Date()
            } else {
                try store.updateReconcileProgress(runID: runID, phase: DomainCheckProgress.Phase.scanningFiles.rawValue, scanned: scanProgress().scanned, expected: expectedItems)
            }
        }
        if savedCursor == nil {
            try store.updateReconcile(runID: runID, phase: "scanning_normal", cursor: rootScope.rootURI, state: "active", progress: scanProgress())
        } else if let savedCursor {
            try saveCursor(queue: savedCursor.queue, current: savedCursor.current, page: savedCursor.page, token: savedCursor.token, usedTokens: Set(savedCursor.usedTokens), force: true)
        }
        while currentWork != nil || !queue.isEmpty {
            let current = currentWork ?? queue.removeFirst()
            currentWork = current
            repeat {
                guard page <= 2_000 else {
                    throw CoreFailure(code: .quotaExceeded, retryable: false, userActionRequired: true, redactedContext: ["stage": "normal_scan_bound"])
                }
                let requestUsedCursor = token != nil
                let response = try await list(uri: current.uri, page: Int32(page), token: token)
                logger.info("reconcile.page id=\(correlationID, privacy: .public) page=\(page, privacy: .public) token=\(token != nil, privacy: .public) items=\(response.files.count, privacy: .public)")
                // Progress only: overwriting the cursor here with "page:N" lost the resumable
                // position whenever the app stopped while a page was being applied.
                try store.updateReconcileProgress(runID: runID, phase: DomainCheckProgress.Phase.scanningFiles.rawValue, scanned: scanProgress().scanned, expected: expectedItems)
                for file in response.files {
                    guard file.id != descriptor.rootRemoteID else { continue }
                    if !seen.contains(file.id) {
                        guard seen.count < DomainScale.maximumItems else {
                            throw CoreFailure(code: .quotaExceeded, retryable: false, userActionRequired: true, redactedContext: ["stage": "normal_scan_bound"])
                        }
                    }
                    guard let normalizedPath = canonicalURI(file.path, accountID: descriptor.accountID), CloudreveRemoteURI.isWithin(normalizedPath, root: rootScope.rootURI) else { throw CoreFailure(code: .scopeConflict, retryable: false, userActionRequired: true) }
                    let knownIdentifier = try store.itemIdentifier(forRemoteID: file.id)
                    // An unfinished upload's placeholder is not a file yet; recording it put a
                    // second item under the uploader's name. Known items are left as they were.
                    if knownIdentifier == nil, file.fields.hasActiveUploadSession { continue }
                    let itemIdentifier = knownIdentifier ?? CloudreveIdentifier.item()
                    let item = try makeItem(file, parentIdentifier: current.parent, itemIdentifier: itemIdentifier, accountID: descriptor.accountID, capabilities: descriptor.capabilitySnapshot)
                    let visibility = try store.isExcludedByCurrentRules(item: item, domainIdentifier: descriptor.identifier)
                    let old = try store.item(identifier: itemIdentifier)
                    let wasViewExcluded = try store.localItemState(identifier: itemIdentifier).viewExcluded
                    if visibility.excluded && !wasViewExcluded {
                        _ = try store.commitProviderViewChange(item: item, oldParentIdentifier: old?.parentIdentifier, newParentIdentifier: item.parentIdentifier, excluded: true, origin: "reconciliation")
                    } else if !visibility.excluded && wasViewExcluded {
                        _ = try store.commitProviderViewChange(item: item, oldParentIdentifier: old?.parentIdentifier, newParentIdentifier: item.parentIdentifier, excluded: false, origin: "reconciliation")
                    } else if let old, old == item {
                        try store.insertItem(item)
                    } else if visibility.excluded {
                        try store.insertItem(item)
                    } else {
                        _ = try store.commitProviderChange(item: item, oldParentIdentifier: old?.parentIdentifier, newParentIdentifier: item.parentIdentifier, kind: "reconciled", origin: "reconciliation")
                    }
                    seen.insert(file.id)
                    if file.type == 1 { queue.append(ReconcileWork(uri: normalizedPath, parent: itemIdentifier)) }
                }
                if let nextToken = response.pagination?.nextToken {
                    guard reconciliationPaginationIsVerified(descriptor.capabilitySnapshot, usesCursor: true) else {
                        throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_capability"])
                    }
                    guard !nextToken.isEmpty, usedTokens.insert(nextToken).inserted, usedTokens.count <= 2_000 else { throw CoreFailure(code: .unknownOutcome, retryable: true) }
                    token = nextToken; page = 0
                    try saveCursor(queue: queue, current: current, page: page, token: token, usedTokens: usedTokens)
                } else if requestUsedCursor {
                    guard reconciliationPaginationIsVerified(descriptor.capabilitySnapshot, usesCursor: true) else {
                        throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_completion_capability"])
                    }
                    break
                } else if let total = response.pagination?.totalItems {
                    let effectivePageSize = max(1, response.pagination?.pageSize ?? response.files.count)
                    let currentPage = max(1, response.pagination?.page ?? page)
                    let hasAnotherPage = Int64(currentPage) * Int64(effectivePageSize) < total
                    if hasAnotherPage {
                        guard reconciliationPaginationIsVerified(descriptor.capabilitySnapshot, usesCursor: false) else {
                            throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_capability"])
                        }
                        guard !response.files.isEmpty else {
                            throw CoreFailure(code: .unknownOutcome, retryable: true, userActionRequired: true, redactedContext: ["stage": "normal_scan_incomplete"])
                        }
                    } else {
                        guard reconciliationPaginationIsVerified(descriptor.capabilitySnapshot, usesCursor: false) else {
                            throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_completion_capability"])
                        }
                        break
                    }
                    page = currentPage + 1; token = nil
                    try saveCursor(queue: queue, current: current, page: page, token: token, usedTokens: usedTokens)
                } else if response.files.count >= 500 {
                    // Without an explicit total/token, a full page is not
                    // proof that the scan is complete. Continue by page and
                    // keep the cursor durable; otherwise a missing tail
                    // could be misclassified as a tombstone.
                    guard reconciliationPaginationIsVerified(descriptor.capabilitySnapshot, usesCursor: false) else {
                        throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_capability"])
                    }
                    page += 1
                    token = nil
                    try saveCursor(queue: queue, current: current, page: page, token: token, usedTokens: usedTokens)
                } else {
                    guard reconciliationPaginationIsVerified(descriptor.capabilitySnapshot, usesCursor: false) else {
                        throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_completion_capability"])
                    }
                    break
                }
            } while true
            currentWork = nil
            page = 1
            token = nil
            usedTokens.removeAll()
            try saveCursor(queue: queue, current: nil, page: page, token: nil, usedTokens: usedTokens)
        }
        if descriptor.capabilitySnapshot.canTrash && deletionSafe {
            try store.updateSyncState(reconcileStatus: "scanning_trash")
            try store.updateReconcileProgress(runID: runID, phase: DomainCheckProgress.Phase.scanningTrash.rawValue, scanned: scanProgress().scanned, expected: expectedItems)
            let scannedBeforeTrash = scanProgress().scanned
            let trashFiles = try await listTrash(capability: descriptor.capabilitySnapshot) { listed in
                // The account-wide trash can take many pages; report each one so the check
                // neither looks frozen nor goes silent long enough to be taken for dead.
                try? self.store.updateReconcileProgress(runID: runID, phase: DomainCheckProgress.Phase.scanningTrash.rawValue, scanned: scannedBeforeTrash + listed, expected: expectedItems)
            }
            var unrepresentableTrash = 0
            for file in trashFiles {
                guard file.id != descriptor.rootRemoteID else { continue }
                // The trash listing is account-wide. Its original location decides whether an
                // entry belongs to this domain at all.
                if let restore = file.fields.metadata[CloudreveFileFields.restoreURIMetadataKey],
                   let original = canonicalURI(restore, accountID: descriptor.accountID),
                   !CloudreveRemoteURI.isWithin(original, root: rootScope.rootURI) {
                    continue
                }
                // Cloudreve names trashed files by their trash path (cloudreve://trash/…), which
                // this client cannot address. That used to throw scopeConflict for the whole run,
                // so no full reconcile ever reached deletion detection. Such an entry is skipped,
                // and counted as seen so a known item that is merely in the trash is never
                // mistaken for a permanent deletion.
                guard let normalizedPath = canonicalURI(file.path, accountID: descriptor.accountID),
                      CloudreveRemoteURI.isWithin(normalizedPath, root: rootScope.rootURI) else {
                    seen.insert(file.id)
                    unrepresentableTrash += 1
                    continue
                }
                let itemIdentifier = try store.itemIdentifier(forRemoteID: file.id) ?? CloudreveIdentifier.item()
                var item = try makeItem(file, parentIdentifier: NSFileProviderItemIdentifier.trashContainer.rawValue, itemIdentifier: itemIdentifier, accountID: descriptor.accountID, capabilities: descriptor.capabilitySnapshot)
                let previous = try store.item(identifier: itemIdentifier)
                item.trashed = true
                item.trashOriginalParentIdentifier = previous?.trashOriginalParentIdentifier ?? previous?.parentIdentifier
                item.uri = normalizedPath
                item.canDelete = descriptor.capabilitySnapshot.canPurge && (file.capability?.contains("d") ?? false)
                if previous == item {
                    try store.insertItem(item)
                } else {
                    _ = try store.commitProviderChange(item: item, oldParentIdentifier: previous?.parentIdentifier, newParentIdentifier: item.parentIdentifier, kind: "trash_reconciled", origin: "reconciliation")
                }
                seen.insert(file.id)
            }
            if unrepresentableTrash > 0 {
                logger.info("reconcile.trash.skipped id=\(correlationID, privacy: .public) count=\(unrepresentableTrash, privacy: .public)")
                ActivityLog.shared.info("sync", "Skipped \(unrepresentableTrash) trash entries this client cannot address")
            }
            try store.updateReconcileProgress(runID: runID, phase: DomainCheckProgress.Phase.applyingDeletions.rawValue, scanned: scanProgress().scanned, expected: expectedItems)
            var identitiesChecked = 0
            for identity in try store.remoteIdentities() {
                identitiesChecked += 1
                if identitiesChecked % 2_000 == 0 {
                    try? store.updateReconcileProgress(runID: runID, phase: DomainCheckProgress.Phase.applyingDeletions.rawValue, scanned: scanProgress().scanned, expected: expectedItems)
                }
                guard knownRemoteIDs.contains(identity.remoteID),
                      !seen.contains(identity.remoteID),
                      identity.remoteID != descriptor.rootRemoteID,
                      !(try store.hasPendingWork(itemIdentifier: identity.itemIdentifier)),
                      let item = try store.item(identifier: identity.itemIdentifier),
                      item.remoteID == identity.remoteID,
                      !item.tombstone else { continue }
                var tombstone = item
                tombstone.tombstone = true
                _ = try store.commitProviderChange(item: tombstone, oldParentIdentifier: item.parentIdentifier, newParentIdentifier: nil, kind: "deleted", origin: "reconciliation")
            }
        }
        try store.updateReconcile(runID: runID, phase: "completed", cursor: nil, state: "completed")
        try? store.compactJournal()
        try? store.compactTransferState()
        try store.updateSyncState(reconcileAt: Date(), reconcileStatus: "completed")
        logger.info("reconcile.completed id=\(correlationID, privacy: .public) domain=\(descriptor.identifier, privacy: .public)")
        ActivityLog.shared.info("sync", "Full check completed")
        } catch {
            var persistedCursor: String?
            if let latestCursor, let data = try? Self.encodeCursor(latestCursor) {
                persistedCursor = String(data: data, encoding: .utf8)
            } else if let runs = try? store.activeReconcileRuns() {
                persistedCursor = runs.first(where: { $0.id == runID })?.cursor
            }
            try? store.updateReconcile(runID: runID, phase: "failed", cursor: persistedCursor, state: "failed")
            try? store.updateSyncState(reconcileStatus: "error:\(reconciliationErrorCode(error))")
            let failureStage = (error as? CoreFailure)?.redactedContext["stage"] ?? "-"
            logger.error("reconcile.failed id=\(correlationID, privacy: .public) domain=\(descriptor.identifier, privacy: .public) code=\(reconciliationErrorCode(error), privacy: .public) stage=\(failureStage, privacy: .public)")
            ActivityLog.shared.error("sync", "Full check failed · code=\(reconciliationErrorCode(error)) stage=\(failureStage)")
            throw error
        }
    }

    static let cursorWriteInterval: TimeInterval = 10
    /// Tens of thousands of queued folders fit; past this the position is dropped and the next
    /// attempt starts over, rather than writing an unbounded row.
    static let maximumCursorBytes = 16 * 1024 * 1024

    private static func encodeCursor(_ cursor: ReconcileCursor) throws -> Data {
        let data = try JSONEncoder().encode(cursor)
        guard data.count <= maximumCursorBytes else {
            return try JSONEncoder().encode(ReconcileCursor(queue: [], current: nil, page: 1, token: nil, usedTokens: []))
        }
        return data
    }

    private func persistCursor(runID: UUID, cursor: ReconcileCursor, progress: (scanned: Int, expected: Int)) throws {
        let data = try Self.encodeCursor(cursor)
        try store.updateReconcile(runID: runID, phase: "scanning_normal", cursor: String(data: data, encoding: .utf8), state: "active", progress: progress)
    }

    private func fetchFile(id: String) async throws -> EventFileDTO {
        let value: EventFileDTO? = try await request(path: "file/info", query: [URLQueryItem(name: "id", value: id), URLQueryItem(name: "extended", value: "true")])
        guard let value else { throw CoreFailure(code: .rootUnavailable, retryable: false, userActionRequired: true) }
        return value
    }

    private func list(uri: String, page: Int32, token: String?) async throws -> ReconcileListDTO {
        var query = [URLQueryItem(name: "uri", value: uri), URLQueryItem(name: "page_size", value: "500"), URLQueryItem(name: "order_by", value: "name"), URLQueryItem(name: "order_direction", value: "asc")]
        if let token { query.append(URLQueryItem(name: "next_page_token", value: token)) } else { query.append(URLQueryItem(name: "page", value: String(page))) }
        guard let value: ReconcileListDTO = try await request(path: "file", query: query) else { throw CoreFailure(code: .unknownOutcome, retryable: true, redactedContext: ["stage": "list_rejected"]) }
        return value
    }

    private func listTrash(capability: CapabilitySnapshot, onPage: (Int) -> Void = { _ in }) async throws -> [EventFileDTO] {
        var page = 1
        var token: String?
        var result: [EventFileDTO] = []
        var usedTokens = Set<String>()
        while true {
            guard page <= 2_000 else {
                throw CoreFailure(code: .quotaExceeded, retryable: false, userActionRequired: true, redactedContext: ["stage": "trash_scan_bound"])
            }
            let query = [
                URLQueryItem(name: "uri", value: "cloudreve://trash"),
                URLQueryItem(name: "page_size", value: "500"),
                URLQueryItem(name: "order_by", value: "name"),
                URLQueryItem(name: "order_direction", value: "asc")
            ] + (token.map { [URLQueryItem(name: "next_page_token", value: $0)] } ?? [URLQueryItem(name: "page", value: String(page))])
            let requestUsedCursor = token != nil
            guard let response: ReconcileListDTO = try await request(path: "file", query: query) else {
                throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true)
            }
            result.append(contentsOf: response.files)
            onPage(result.count)
            guard result.count <= DomainScale.maximumItems else {
                throw CoreFailure(code: .quotaExceeded, retryable: false, userActionRequired: true, redactedContext: ["stage": "trash_scan_bound"])
            }
            if let next = response.pagination?.nextToken {
                guard reconciliationPaginationIsVerified(capability, usesCursor: true) else {
                    throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_capability"])
                }
                guard !next.isEmpty, usedTokens.insert(next).inserted, usedTokens.count <= 2_000 else { throw CoreFailure(code: .unknownOutcome, retryable: true) }
                token = next
                continue
            }
            if requestUsedCursor {
                guard reconciliationPaginationIsVerified(capability, usesCursor: true) else {
                    throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_completion_capability"])
                }
                return result
            }
            if let total = response.pagination?.totalItems, Int64(result.count) < total {
                guard reconciliationPaginationIsVerified(capability, usesCursor: false) else {
                    throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_capability"])
                }
                guard !response.files.isEmpty else {
                    throw CoreFailure(code: .unknownOutcome, retryable: true, userActionRequired: true, redactedContext: ["stage": "trash_scan_incomplete"])
                }
                page += 1
                token = nil
                continue
            }
            if response.pagination == nil && response.files.count >= 500 {
                guard reconciliationPaginationIsVerified(capability, usesCursor: false) else {
                    throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_capability"])
                }
                page += 1
                continue
            }
            guard reconciliationPaginationIsVerified(capability, usesCursor: false) else {
                throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_completion_capability"])
            }
            return result
        }
    }

    private func request<Value: Decodable>(path: String, query: [URLQueryItem]) async throws -> Value? {
        var components = URLComponents(url: origin.appendingPathComponent("api/v4").appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.setCloudreveQueryItems(query)
        guard let url = components?.url else { throw CoreFailure(code: .network, retryable: true) }
        logger.info("reconcile.request.begin endpoint=\(path, privacy: .public)")
        let credential = try await credentialRefresh.credential(origin: origin, reference: credentialReference)
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CoreFailure(code: .network, retryable: true) }
        logger.info("reconcile.request.response endpoint=\(path, privacy: .public) status=\(http.statusCode, privacy: .public)")
        if http.statusCode == 401 { throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true) }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw CoreFailure(code: .network, retryable: true) }
        let envelope = try JSONDecoder().decode(EventAPIEnvelope<Value>.self, from: data)
        guard envelope.code == 0 else {
            let uriShape = query.first(where: { $0.name == "uri" })?.value.map(CloudreveRemoteURI.diagnosticShape) ?? "-"
            logger.error("reconcile.request.rejected endpoint=\(path, privacy: .public) api_code=\(envelope.code, privacy: .public) uri_shape=\(uriShape, privacy: .public)")
            ActivityLog.shared.warning("sync", "Server rejected a listing · api_code=\(envelope.code) uri_shape=\(uriShape)")
            return nil
        }
        return envelope.data
    }

    private func makeItem(_ file: EventFileDTO, parentIdentifier: String, itemIdentifier: String, accountID: String, capabilities: CapabilitySnapshot) throws -> RemoteItem {
        let normalizedPath = try CloudreveRemoteURI.canonical(file.path, accountID: accountID)
        return CloudreveItemMapper.item(from: file.fields, normalizedURI: normalizedPath, parentIdentifier: parentIdentifier, itemIdentifier: itemIdentifier, capabilities: capabilities)
    }
}

func reconciliationErrorCode(_ error: Error) -> String {
    if let failure = error as? CoreFailure { return failure.code.rawValue }
    if let failure = error as? StoreBridgeError {
        switch failure {
        case .openFailed: return "store_open_failed"
        case .sql: return "store_sql"
        case .schemaFenced: return "schema_fenced"
        case .anchorExpired: return "anchor_expired"
        case .pageTokenInvalid: return "page_token_invalid"
        case .snapshotExpired: return "snapshot_expired"
        case .generationFenced: return "generation_fenced"
        case .corrupted: return "store_corrupted"
        case .unknownDomain: return "unknown_domain"
        }
    }
    if error is CancellationError { return "cancelled" }
    let nsError = error as NSError
    return "error_\(nsError.domain)_\(nsError.code)"
}

public struct StableRootObservation: Sendable, Equatable {
    public let remoteID: String
    public let uri: String
    public let accountID: String
    public let canRead: Bool
    public init(remoteID: String, uri: String, accountID: String, canRead: Bool) { self.remoteID = remoteID; self.uri = uri; self.accountID = accountID; self.canRead = canRead }
}

public enum RootConsistencyResult: Sendable, Equatable {
    case unchanged
    case routeUpdated(uri: String)
    case unavailable
    case scopeConflict
    case replaced
}

public struct StableRootChecker: Sendable {
    public let expectedRemoteID: String
    public let expectedAccountID: String
    public let existingScopes: [RemoteScope]
    public init(expectedRemoteID: String, expectedAccountID: String, existingScopes: [RemoteScope] = []) { self.expectedRemoteID = expectedRemoteID; self.expectedAccountID = expectedAccountID; self.existingScopes = existingScopes }

    public func check(_ observation: StableRootObservation, currentScope: RemoteScope) -> RootConsistencyResult {
        guard observation.canRead, observation.accountID == expectedAccountID else { return .unavailable }
        guard observation.remoteID == expectedRemoteID else { return .replaced }
        guard let newScope = try? RemoteScope(origin: currentScope.origin, accountID: currentScope.accountID, rootURI: observation.uri) else { return .unavailable }
        if existingScopes.contains(where: { $0.overlaps(newScope) && $0.rootURI != currentScope.rootURI }) { return .scopeConflict }
        return newScope.rootURI == currentScope.rootURI ? .unchanged : .routeUpdated(uri: newScope.rootURI)
    }
}

public struct EventHintDecoder: Sendable {
    public init() {}
    public func decode(_ hint: RemoteEventHint) throws -> RemoteEventPayload {
        guard let data = hint.payload?.data(using: .utf8), !data.isEmpty else { throw EventEnrichmentError.malformedHint }
        guard let payload = try? JSONDecoder().decode(RemoteEventPayload.self, from: data), payload.type != nil || payload.id != nil else { throw EventEnrichmentError.malformedHint }
        return payload
    }
}

public protocol RemoteEventEnricher: Sendable {
    func enrich(_ hint: RemoteEventHint) async throws -> EnrichedRemoteChange?
}

/// What consuming one live update did. Only `skipped` leaves the change for the next full check.
public enum EventConsumeOutcome: Equatable, Sendable {
    /// The change was written to the local state.
    case applied
    /// Nothing to write: our own change echoed back, a version already applied, or a file whose
    /// upload has not finished yet.
    case unchanged
    /// The event concerns something outside this Domain, such as the Domain's root folder or
    /// another folder of the same account.
    case outsideScope
    /// The change could not be applied; `reason` is a short, redacted code for the log.
    case skipped(reason: String)
}

public actor EventNormalizationPipeline {
    private var scopeGuard: EventScopeGuard
    private let enricher: RemoteEventEnricher
    private let writer: EventJournalWriter
    private var seenVersions: [String: ItemVersion] = [:]
    private var pendingScopes: Set<String> = []

    public init(scopeGuard: EventScopeGuard, enricher: RemoteEventEnricher, writer: EventJournalWriter) { self.scopeGuard = scopeGuard; self.enricher = enricher; self.writer = writer }

    public func consume(_ hint: RemoteEventHint, echo: EchoEvidence? = nil) async -> EventConsumeOutcome {
        guard scopeGuard.accepts(remoteID: hint.remoteID, fromURI: hint.fromURI, toURI: hint.toURI) else {
            pendingScopes.insert(hint.fromURI ?? hint.toURI ?? "root")
            return .outsideScope
        }
        do {
            guard let change = try await enricher.enrich(hint) else {
                // The server no longer has the item: usually a delete. Deletions stay with the
                // full check, which can prove an item is gone rather than briefly unreadable.
                pendingScopes.insert(hint.fromURI ?? hint.toURI ?? "root")
                return .skipped(reason: "not_found")
            }
            let versionKey = change.item.remoteID ?? change.item.itemIdentifier
            // Without echo evidence the matcher says `.unknown`, which still means "apply it".
            if EchoMatcher.match(echo, item: change.item) == .matched || seenVersions[versionKey] == change.item.version {
                seenVersions[versionKey] = change.item.version
                return .unchanged
            }
            do {
                _ = try await writer.commit(change)
            } catch {
                pendingScopes.insert(hint.fromURI ?? hint.toURI ?? "root")
                return .skipped(reason: "store_\(reconciliationErrorCode(error))")
            }
            seenVersions[versionKey] = change.item.version
            return .applied
        } catch EventEnrichmentError.pendingUpload {
            return .unchanged
        } catch EventEnrichmentError.outsideScope {
            pendingScopes.insert(hint.fromURI ?? hint.toURI ?? "root")
            return .outsideScope
        } catch let error as EventEnrichmentError {
            pendingScopes.insert(hint.fromURI ?? hint.toURI ?? "root")
            return .skipped(reason: error == .malformedHint ? "malformed_event" : "server_unavailable")
        } catch {
            pendingScopes.insert(hint.fromURI ?? hint.toURI ?? "root")
            return .skipped(reason: reconciliationErrorCode(error))
        }
    }

    public func scopesNeedingReconciliation() -> [String] { pendingScopes.sorted() }
    public func clearReconciledScope(_ scope: String) { pendingScopes.remove(scope) }
    public func rejectedEvents() -> Int { scopeGuard.rejectedCount }
}

public struct ReconcileItemSet: Sendable, Equatable {
    public let expectedRemoteIDs: Set<String>
    public let normalRemoteIDs: Set<String>
    public let trashRemoteIDs: Set<String>
    public let pendingRemoteIDs: Set<String>
    public let normalComplete: Bool
    public let trashComplete: Bool
    public init(expectedRemoteIDs: Set<String>, normalRemoteIDs: Set<String>, trashRemoteIDs: Set<String>, pendingRemoteIDs: Set<String>, normalComplete: Bool, trashComplete: Bool) { self.expectedRemoteIDs = expectedRemoteIDs; self.normalRemoteIDs = normalRemoteIDs; self.trashRemoteIDs = trashRemoteIDs; self.pendingRemoteIDs = pendingRemoteIDs; self.normalComplete = normalComplete; self.trashComplete = trashComplete }
}

public struct ReconcileSafety: Sendable {
    public init() {}
    public func tombstoneCandidates(_ set: ReconcileItemSet) -> [String] {
        guard set.normalComplete && set.trashComplete else { return [] }
        return set.expectedRemoteIDs.subtracting(set.normalRemoteIDs).subtracting(set.trashRemoteIDs).subtracting(set.pendingRemoteIDs).sorted()
    }
}

public actor ReconciliationCoordinator {
    private let store: SQLiteStateStore
    private var activeRun: ReconcileGeneration?
    private let safety = ReconcileSafety()

    public init(store: SQLiteStateStore) { self.store = store }

    public func begin(generation: UInt64, capabilityRevision: UInt64, rootRemoteID: String) throws -> ReconcileGeneration {
        let state = try store.syncState()
        let run = ReconcileGeneration(generation: generation, capabilityRevision: capabilityRevision, rootRemoteID: rootRemoteID, startSequence: state.currentSequence)
        activeRun = run
        try store.startReconcile(runID: run.runID, scope: "domain", generation: generation, phase: run.phase.rawValue, cursor: nil)
        try store.updateSyncState(reconcileStatus: "reconciling")
        return run
    }

    public func recordPage(cursor: String?, phase: ReconcileGeneration.Phase) throws {
        guard var run = activeRun else { throw CoreFailure(code: .unknownOutcome, retryable: true) }
        run.cursor = cursor; run.phase = phase; activeRun = run
        try store.updateReconcile(runID: run.runID, phase: phase.rawValue, cursor: cursor, state: "active")
    }

    public func finish(run: ReconcileGeneration, safetySet: ReconcileItemSet, currentCapabilityRevision: UInt64, currentRootRemoteID: String) throws -> [String] {
        guard run.normalComplete && run.trashComplete else { throw CoreFailure(code: .unknownOutcome, retryable: true) }
        var candidateRun = run
        try candidateRun.stabilize()
        try candidateRun.beginDeletionCommit(currentCapabilityRevision: currentCapabilityRevision, currentRootRemoteID: currentRootRemoteID)
        let tombstones = safety.tombstoneCandidates(safetySet)
        candidateRun.complete()
        activeRun = nil
        try store.updateReconcile(runID: candidateRun.runID, phase: candidateRun.phase.rawValue, cursor: nil, state: "completed")
        try store.updateSyncState(reconcileAt: Date(), reconcileStatus: "completed")
        return tombstones
    }

    public func abort() throws {
        guard let run = activeRun else { return }
        activeRun = nil
        try store.updateReconcile(runID: run.runID, phase: ReconcileGeneration.Phase.failed.rawValue, cursor: run.cursor, state: "failed")
        try store.updateSyncState(reconcileStatus: "error")
    }
}

public struct ReconcileGeneration: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case prepared, scanningNormal = "scanning_normal", scanningTrash = "scanning_trash", stabilizing, committingDeletions = "committing_deletions", completed, failed }
    public let runID: UUID
    public let generation: UInt64
    public let capabilityRevision: UInt64
    public let rootRemoteID: String
    public var phase: Phase
    public var normalComplete: Bool
    public var trashComplete: Bool
    public var cursor: String?
    public var startSequence: Int64
    public init(runID: UUID = UUID(), generation: UInt64, capabilityRevision: UInt64, rootRemoteID: String, startSequence: Int64) { self.runID = runID; self.generation = generation; self.capabilityRevision = capabilityRevision; self.rootRemoteID = rootRemoteID; self.phase = .prepared; self.normalComplete = false; self.trashComplete = false; self.cursor = nil; self.startSequence = startSequence }
    public mutating func startNormal() { phase = .scanningNormal }
    public mutating func startTrash() { phase = .scanningTrash }
    public mutating func finishNormal() { normalComplete = true }
    public mutating func finishTrash() { trashComplete = true }
    public mutating func stabilize() throws { guard normalComplete && trashComplete else { phase = .failed; throw CoreFailure(code: .unknownOutcome, retryable: true) }; phase = .stabilizing }
    public mutating func beginDeletionCommit(currentCapabilityRevision: UInt64, currentRootRemoteID: String) throws { guard phase == .stabilizing, capabilityRevision == currentCapabilityRevision, rootRemoteID == currentRootRemoteID else { phase = .failed; throw CoreFailure(code: .rootUnavailable, retryable: false, userActionRequired: true) }; phase = .committingDeletions }
    public mutating func complete() { phase = .completed }
}

public actor MaterializedSetTracker {
    private let store: SQLiteStateStore
    private var degraded = false
    public init(store: SQLiteStateStore) { self.store = store }
    public func mark(_ identifier: String, materialized: Bool) { try? store.setMaterialized(identifier, materialized: materialized) }
    public func markDegraded() { degraded = true }
    public func isDegraded() -> Bool { degraded }
    public func shouldSignal(parentIdentifiers: [String], oldParent: String?, newParent: String?) -> Bool {
        let values = Set(parentIdentifiers)
        return oldParent.map(values.contains) ?? false || newParent.map(values.contains) ?? false
    }
}

public actor PendingSetTracker {
    private let store: SQLiteStateStore
    public init(store: SQLiteStateStore) { self.store = store }
    public func update(itemIdentifier: String, templateIdentifier: String?, uploadError: String?, downloadError: String?) { try? store.setPending(itemIdentifier, templateIdentifier: templateIdentifier, uploadError: uploadError, downloadError: downloadError) }
    public func snapshot() -> (count: Int, capped: Bool) { (try? store.pendingSetState()) ?? (0, true) }
}

public actor FairDomainScheduler {
    private var queue: [String] = []
    private var active: Set<String> = []
    private let limit: Int
    public init(limit: Int = 2) { self.limit = max(1, limit) }
    public func enqueue(_ domainID: String) { if !queue.contains(domainID) && !active.contains(domainID) { queue.append(domainID) } }
    public func next() -> String? { guard active.count < limit, !queue.isEmpty else { return nil }; let value = queue.removeFirst(); active.insert(value); return value }
    public func finish(_ domainID: String) { active.remove(domainID) }
    public func queued() -> [String] { queue }
    public func activeDomains() -> [String] { active.sorted() }
}

public actor HeartbeatCoordinator {
    private var lastHeartbeat: Date?
    private var appRunning = true
    private let store: SQLiteStateStore?
    private let role: String
    private let instanceID: UUID
    public init(store: SQLiteStateStore? = nil, role: String = "app", instanceID: UUID = UUID()) { self.store = store; self.role = role; self.instanceID = instanceID }
    public func beat(at date: Date = Date()) { lastHeartbeat = date; appRunning = true; try? store?.recordHeartbeat(role: role, instanceID: instanceID, bundleVersion: "0.1.0", schemaGeneration: 1, at: date) }
    public func markQuit() { appRunning = false; try? store?.updateSyncState(reconcileStatus: "app_not_running") }
    public func isFresh(now: Date = Date(), timeout: TimeInterval = 90) -> Bool { appRunning && lastHeartbeat.map { now.timeIntervalSince($0) <= timeout } ?? false }
}

public final class LoginItemCoordinator: @unchecked Sendable {
    public init() {}
    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    public func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

public struct DomainConsistencyProjection: Sendable {
    public var inputs: HealthInputs
    public init(inputs: HealthInputs = HealthInputs()) { self.inputs = inputs }
    public mutating func setAppRunning(_ value: Bool) { inputs.appRunning = value }
    public mutating func setEventDegraded(_ value: Bool) { inputs.eventDegraded = value }
    public mutating func setReconciling(_ value: Bool) { inputs.reconciling = value }
    public func status() -> DomainStatus { DomainHealthReducer.reduce(inputs) }
}

/// Production wiring for one Domain's live event path. It deliberately keeps
/// reconciliation as a persisted request until the full normal/trash scan
/// worker is available. A resumed subscription keeps a Domain that already finished a check
/// current: the server replays what this client ID missed.
public actor DomainEventRuntime: EventSupervisorDelegate {
    private let store: SQLiteStateStore
    private let registry: SQLiteStateStore?
    private var pipeline: EventNormalizationPipeline
    private let reconciler: CloudreveReconciliationService
    private let outboxDrainer: SignalOutboxDrainer
    private let vault: CredentialVault
    private var connectionState: ConnectionState = .stopped
    private let domainIdentifier: String
    private var currentRootURI: String
    private var streamRestartRequired = false
    private let onRootChanged: (@Sendable (String) async -> Void)?
    private let onConnectionStateChanged: (@Sendable (ConnectionState) async -> Void)?
    /// One full check at a time; requests while one runs are dropped, not queued.
    private var fullCheckInFlight = false
    /// A Domain that never finished a check retries that first check once per app session.
    private var initialCheckAttempted = false
    /// Events received since `resumed`, until the first keep-alive ends the replay.
    private var replay: (count: Int, itemCount: Int)?

    public init?(descriptor: DomainDescriptor, store: SQLiteStateStore, registry: SQLiteStateStore? = nil, vault: CredentialVault, onRootChanged: (@Sendable (String) async -> Void)? = nil, onConnectionStateChanged: (@Sendable (ConnectionState) async -> Void)? = nil) {
        guard let origin = URL(string: descriptor.scope.origin) else { return nil }
        self.store = store
        self.registry = registry
        self.domainIdentifier = descriptor.identifier
        self.currentRootURI = descriptor.currentRootURI
        self.onRootChanged = onRootChanged
        self.onConnectionStateChanged = onConnectionStateChanged
        self.vault = vault
        let enricher = CloudreveEventEnricher(origin: origin, rootURI: descriptor.currentRootURI, rootRemoteID: descriptor.rootRemoteID, store: store, vault: vault, credentialReference: descriptor.secretReference, capabilitySnapshot: descriptor.capabilitySnapshot)
        self.reconciler = CloudreveReconciliationService(origin: origin, store: store, registry: registry, vault: vault, credentialReference: descriptor.secretReference)
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(descriptor.identifier), displayName: descriptor.displayName)
        let signaller = FileProviderWorkingSetSignaller(domain: domain)
        let drainer = SignalOutboxDrainer(store: store, signaller: signaller)
        self.outboxDrainer = drainer
        self.pipeline = EventNormalizationPipeline(scopeGuard: EventScopeGuard(rootRemoteID: descriptor.rootRemoteID, rootURI: descriptor.currentRootURI), enricher: enricher, writer: EventJournalWriter(store: store, outboxDrainer: drainer))
    }

    public func handle(hint: RemoteEventHint) async {
        countReplayedEvent()
        switch await pipeline.consume(hint) {
        case .applied, .unchanged:
            try? store.updateSyncState(eventAt: Date(), reconcileStatus: "event_active")
        case .outsideScope:
            break
        case .skipped(reason: "not_found"):
            // Expected after a delete on the server; not a fault worth a warning.
            ActivityLog.shared.info("live-updates", "A change named an item the server no longer has; the next full check removes it")
        case .skipped(let reason):
            // A full check per unresolvable event cost far more than it saved; the fallback
            // check picks the change up.
            ActivityLog.shared.warning("live-updates", "Skipped a change that could not be applied · reason=\(reason)")
        }
    }

    // MARK: - Deciding on full checks

    public func subscriptionConfirmed(resumed: Bool) async {
        recoverAbandonedCheck()
        let hasCompletedCheck = hasCompletedFullCheck()
        if let reason = FullCheckPolicy.reasonAfterSubscription(resumed: resumed, hasCompletedCheck: hasCompletedCheck, initialCheckAttemptedThisSession: initialCheckAttempted) {
            if !hasCompletedCheck { initialCheckAttempted = true }
            ActivityLog.shared.info("live-updates", resumed ? "Live updates resumed" : "New live-update subscription; changes made meanwhile may be missing")
            startFullCheck(reason: reason)
            return
        }
        ActivityLog.shared.info("live-updates", "Live updates resumed; applying changes made meanwhile")
        replay = (0, (try? store.remoteItemCount()) ?? 0)
        promoteAfterResume(hasCompletedCheck: hasCompletedCheck)
    }

    public func keepAliveReceived() async {
        replay = nil
    }

    public func ignoredUnrecognizedEvent() async {
        ActivityLog.shared.warning("live-updates", "Ignored a live update this version does not understand")
    }

    /// Starts the background fallback check when it is due. Only while connected, so a Mac
    /// without network does not spend its attempt on a check that cannot succeed.
    @discardableResult
    public func startFallbackCheckIfDue(interval: TimeInterval, now: Date = Date()) -> Bool {
        guard connectionState == .subscribed, !fullCheckInFlight else { return false }
        recoverAbandonedCheck(now: now)
        let lastAttempt = (try? store.lastFullCheckAttemptAt()) ?? nil
        guard FullCheckPolicy.isFallbackDue(lastAttempt: lastAttempt, interval: interval, now: now) else { return false }
        startFullCheck(reason: "scheduled")
        return true
    }

    /// The user asked for a full check. False when one is already running.
    @discardableResult
    public func startManualCheck() -> Bool {
        guard !fullCheckInFlight else { return false }
        startFullCheck(reason: "manual")
        return true
    }

    public func isRunningFullCheck() -> Bool { fullCheckInFlight }

    /// Runs off the event path, so the stream keeps draining while the server is listed.
    private func startFullCheck(reason: String) {
        guard !fullCheckInFlight else { return }
        Task { await self.reconcile(reason: reason) }
    }

    private func countReplayedEvent() {
        guard var current = replay else { return }
        current.count += 1
        if FullCheckPolicy.replayCalledForFullCheck(replayedEvents: current.count, itemCount: current.itemCount) {
            replay = nil
            ActivityLog.shared.info("live-updates", "More changes replayed than the domain has items; checking everything instead")
            startFullCheck(reason: "replay_exceeds_items")
        } else {
            replay = current
        }
    }

    /// Cleans up after a check whose process died: its run stays "active" with frozen numbers
    /// and the Domain stays "checking", because nothing else ever records the end. Only
    /// silent runs are touched, so a check still running in the File Provider extension is
    /// left alone.
    @discardableResult
    public func recoverAbandonedCheck(now: Date = Date()) -> Bool {
        guard !fullCheckInFlight else { return false }
        let abandoned = (try? store.failStaleReconcileRuns(silentFor: DomainCheckProgress.staleAfter, now: now)) ?? 0
        if abandoned > 0 {
            ActivityLog.shared.warning("sync", "Found \(abandoned) interrupted full check; it resumes with the next check")
        }
        let stuckChecking = (try? store.domain(identifier: domainIdentifier)?.status) == .reconciling
            || (try? registry?.domain(identifier: domainIdentifier)?.status) == .reconciling
        guard stuckChecking, (try? store.hasLiveReconcileRun(silentFor: DomainCheckProgress.staleAfter, now: now)) == false else {
            return abandoned > 0
        }
        if hasCompletedFullCheck() {
            let next: DomainStatus = (try? store.hasDirtyWork()) == true ? .syncing : .healthy
            try? store.setDomainStatus(identifier: domainIdentifier, status: next)
            try? registry?.setDomainStatus(identifier: domainIdentifier, status: next)
        } else {
            // Without one finished check there is nothing current to show; report the gap
            // honestly until the first check succeeds.
            try? store.setDomainStatus(identifier: domainIdentifier, status: .eventDegraded)
            try? registry?.setDomainStatus(identifier: domainIdentifier, status: .eventDegraded)
        }
        return true
    }

    private func hasCompletedFullCheck() -> Bool {
        ((try? store.syncState())?.lastReconcileAt) != nil
    }

    /// Statuses a resumed subscription may replace; problems that need the user stay visible.
    static let statusesResumeMayReplace: Set<DomainStatus> = [.initializing, .reconciling, .eventDegraded, .appNotRunning, .offline, .healthy, .syncing]

    private func promoteAfterResume(hasCompletedCheck: Bool) {
        guard hasCompletedCheck, !fullCheckInFlight,
              let current = try? store.domain(identifier: domainIdentifier)?.status,
              Self.statusesResumeMayReplace.contains(current) else { return }
        let next: DomainStatus = (try? store.hasDirtyWork()) == true ? .syncing : .healthy
        try? store.setDomainStatus(identifier: domainIdentifier, status: next)
        try? registry?.setDomainStatus(identifier: domainIdentifier, status: next)
    }

    public func markEventDegraded() async {
        try? store.setDomainStatus(identifier: domainIdentifier, status: .eventDegraded)
        try? registry?.setDomainStatus(identifier: domainIdentifier, status: .eventDegraded)
        try? store.updateSyncState(reconcileStatus: "event_degraded")
    }

    public func markAuthenticationExpired() async {
        await publishConnectionState(.authExpired)
        try? store.setDomainStatus(identifier: domainIdentifier, status: .authExpired)
        try? registry?.setDomainStatus(identifier: domainIdentifier, status: .authExpired)
        try? store.updateSyncState(reconcileStatus: "auth_expired")
    }

    /// A full check. Ignored while another one runs.
    public func reconcile(reason: String) async {
        guard !fullCheckInFlight else { return }
        fullCheckInFlight = true
        defer { fullCheckInFlight = false }
        await performFullCheck(reason: reason)
    }

    private func performFullCheck(reason: String) async {
        try? store.setDomainStatus(identifier: domainIdentifier, status: .reconciling)
        try? registry?.setDomainStatus(identifier: domainIdentifier, status: .reconciling)
        try? store.updateSyncState(reconcileStatus: "requested:\(reason)")
        do {
            guard let descriptor = try store.domain(identifier: domainIdentifier), let scope = try? RemoteScope(origin: descriptor.origin, accountID: descriptor.accountID, rootURI: descriptor.rootURI) else { throw CoreFailure(code: .unknownOutcome, retryable: true) }
            var model = DomainDescriptor(identifier: descriptor.identifier, displayName: descriptor.displayName, scope: scope, rootRemoteID: descriptor.rootRemoteID, accountID: descriptor.accountID, secretReference: descriptor.secretReference, capabilitySnapshot: descriptor.capabilitySnapshot, iconURL: descriptor.iconURL)
            model.status = .reconciling
            try await reconciler.reconcile(descriptor: model, reason: reason)
            guard await outboxDrainer.drain() else {
                await markEventDegraded()
                return
            }
            let updated: StoredDomain?
            do { updated = try store.domain(identifier: domainIdentifier) } catch {
                await markEventDegraded()
                return
            }
            guard let updated else {
                await markEventDegraded()
                return
            }
            if updated.rootURI != currentRootURI {
                currentRootURI = updated.rootURI
                let updatedScope = try? RemoteScope(origin: updated.origin, accountID: updated.accountID, rootURI: updated.rootURI)
                if let updatedScope {
                    guard let updatedOrigin = URL(string: updated.origin) else {
                        await markEventDegraded()
                        return
                    }
                    let enricher = CloudreveEventEnricher(origin: updatedOrigin, rootURI: updatedScope.rootURI, rootRemoteID: updated.rootRemoteID, store: store, vault: vault, credentialReference: updated.secretReference, capabilitySnapshot: updated.capabilitySnapshot)
                    pipeline = EventNormalizationPipeline(scopeGuard: EventScopeGuard(rootRemoteID: updated.rootRemoteID, rootURI: updatedScope.rootURI), enricher: enricher, writer: EventJournalWriter(store: store, outboxDrainer: outboxDrainer))
                    streamRestartRequired = true
                    await onRootChanged?(updatedScope.rootURI)
                }
            }
            guard let hasDirtyWork = try? store.hasDirtyWork() else {
                await markEventDegraded()
                return
            }
            let nextStatus: DomainStatus
            if connectionState == .subscribed {
                nextStatus = hasDirtyWork ? .syncing : .healthy
            } else {
                nextStatus = .eventDegraded
            }
            try? store.setDomainStatus(identifier: domainIdentifier, status: nextStatus)
            try? registry?.setDomainStatus(identifier: domainIdentifier, status: nextStatus)
        } catch let failure as CoreFailure {
            if failure.code == .scopeConflict {
                try? store.setDomainStatus(identifier: domainIdentifier, status: .scopeConflict)
                try? registry?.setDomainStatus(identifier: domainIdentifier, status: .scopeConflict)
                return
            }
            if failure.code == .authentication {
                await markAuthenticationExpired()
                return
            }
            try? store.updateSyncState(reconcileStatus: "error:\(failure.code.rawValue)")
            await markEventDegraded()
        } catch {
            try? store.updateSyncState(reconcileStatus: "error")
            await markEventDegraded()
        }
    }

    public func setConnectionState(_ state: ConnectionState) async {
        await publishConnectionState(state)
        switch state {
        case .degraded: await markEventDegraded()
        case .offline:
            try? store.setDomainStatus(identifier: domainIdentifier, status: .offline)
            try? registry?.setDomainStatus(identifier: domainIdentifier, status: .offline)
        case .stopped:
            try? store.setDomainStatus(identifier: domainIdentifier, status: .appNotRunning)
            try? registry?.setDomainStatus(identifier: domainIdentifier, status: .appNotRunning)
        case .connecting:
            // The status waits for the server's reply: `resumed` keeps the Domain current,
            // `subscribed` starts a check.
            break
        case .subscribed:
            _ = await outboxDrainer.drain()
        case .authExpired:
            await markAuthenticationExpired()
        }
    }

    public func isAuthenticationExpired() async -> Bool { connectionState == .authExpired }

    public func currentConnectionState() -> ConnectionState { connectionState }

    /// Records the state and tells the observer about real changes only.
    private func publishConnectionState(_ state: ConnectionState) async {
        let changed = connectionState != state
        connectionState = state
        if changed { await onConnectionStateChanged?(state) }
    }

    public func shouldRestartStream() async -> Bool {
        defer { streamRestartRequired = false }
        return streamRestartRequired
    }
}
