import Foundation
import FileProvider
import UniformTypeIdentifiers
import CryptoKit
import OSLog
import CloudreveAuthKit
import CloudreveDomainKit
import CloudreveStoreBridge

private struct APIEnvelope<Value: Decodable>: Decodable {
    let code: Int
    let msg: String?
    let data: Value?
}

private struct RemoteFileDTO: Decodable {
    let type: Int
    let id: String
    let name: String
    let createdAt: String?
    let updatedAt: String?
    let size: Int64?
    let path: String
    let permission: String?
    let capability: String?
    let primaryEntity: String?

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case name
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case size
        case path
        case permission
        case capability
        case primaryEntity = "primary_entity"
    }
}

private struct StoragePolicyDTO: Decodable {
    let type: String?
    let encryption: Bool?
    let streamingEncryption: Bool?
    enum CodingKeys: String, CodingKey { case type; case encryption; case streamingEncryption = "streaming_encryption" }
}

private struct UploadCredentialDTO: Decodable {
    let sessionID: String
    let expires: Int64
    let chunkSize: Int64
    let credential: String?
    let uploadPolicy: String?
    let mimeType: String?
    let uploadURLs: [String]?
    let callbackSecret: String?
    let completeURL: String?
    let storagePolicy: StoragePolicyDTO?
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case expires
        case chunkSize = "chunk_size"
        case credential
        case uploadPolicy = "upload_policy"
        case mimeType = "mime_type"
        case uploadURLs = "upload_urls"
        case callbackSecret = "callback_secret"
        case completeURL = "completeURL"
        case storagePolicy = "storage_policy"
    }
}

private struct EmptyResponse: Decodable {}

private struct UploadCredentialCache: Codable {
    let sessionID: String
    let credential: String?
    let uploadPolicy: String?
    let mimeType: String?
    let uploadURLs: [String]
    let callbackSecret: String?
    let completeURL: String?
    let provider: String
    let expiresAt: Date?
}

private struct RemotePagination: Decodable {
    let page: Int?
    let pageSize: Int?
    let totalItems: Int64?
    let nextToken: String?

    enum CodingKeys: String, CodingKey {
        case page
        case pageSize = "page_size"
        case totalItems = "total_items"
        case nextToken = "next_token"
    }
}

private struct RemoteListDTO: Decodable {
    let files: [RemoteFileDTO]
    let pagination: RemotePagination?
}

private struct FileURLDTO: Decodable {
    let urls: [EntityURLDTO]
    let expires: String?
}

private struct EntityURLDTO: Decodable {
    let url: String
}

private struct QiniuChunkResponse: Decodable {
    let etag: String?
}

private func isOpaqueTransferComponent(_ value: String, maximumLength: Int = 256) -> Bool {
    guard !value.isEmpty, value.count <= maximumLength else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
        scalar.isASCII && (
            scalar.properties.isAlphabetic ||
            (scalar.value >= 48 && scalar.value <= 57) ||
            scalar == "-" ||
            scalar == "_"
        )
    }
}

private func paginationContinuationIsVerified(_ snapshot: CapabilitySnapshot, usesCursor: Bool) -> Bool {
    snapshot.completePagination == .verified &&
        snapshot.snapshotSafePagination == .verified &&
        (!usesCursor || snapshot.cursorPagination == .verified)
}

private func paginationCompletionIsVerified(_ snapshot: CapabilitySnapshot) -> Bool {
    snapshot.completePagination == .verified &&
        snapshot.snapshotSafePagination == .verified
}

private func isSafeTransferValue(_ value: String, maximumLength: Int = 64 * 1024) -> Bool {
    !value.isEmpty &&
        value.utf8.count <= maximumLength &&
        !value.unicodeScalars.contains { CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
}

private func safeExternalURL(_ value: String) throws -> URL {
    guard let url = URL(string: value),
          url.scheme?.lowercased() == "https",
          let host = url.host,
          !host.isEmpty,
          url.user == nil,
          url.password == nil else {
        throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true)
    }
    return url
}

private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var request = request
        let currentURL = task.currentRequest?.url
        let nextURL = request.url
        if currentURL?.scheme != nextURL?.scheme || currentURL?.host != nextURL?.host || currentURL?.port != nextURL?.port {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(request)
    }
}

/// A bounded synchronous facade around URLSession. File Provider callbacks are
/// callback-based, so the network operation is kept off the main queue and has
/// a hard deadline while preserving the callback's ownership rules.
public final class NimbusSyncRemoteBackend: FileProviderBackend, @unchecked Sendable {
    private let origin: URL
    private let rootURI: String
    private let domainIdentifier: String
    private let store: SQLiteStateStore
    private let vault: CredentialVault
    private let credentialReference: String
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let capabilitySnapshot: CapabilitySnapshot
    private let providerName: String
    private let secretVault: OpaqueSecretVault
    private let credentialRefresh: CredentialRefreshService
    private let logger = Logger(subsystem: "ai.tiy.nimbussync", category: "file-provider-download")
    private let clientID: String?

    public init(origin: URL, rootURI: String, store: SQLiteStateStore, vault: CredentialVault, credentialReference: String, capabilitySnapshot: CapabilitySnapshot = CapabilitySnapshot(), providerName: String = "unverified", secretVault: OpaqueSecretVault, requestTimeout: TimeInterval = 60, clientID: String? = nil, domainIdentifier: String? = nil, urlSessionConfiguration: URLSessionConfiguration? = nil) {
        self.origin = origin
        self.rootURI = rootURI
        self.domainIdentifier = domainIdentifier ?? ((try? store.allDomains().first?.identifier) ?? "domain")
        self.store = store
        self.vault = vault
        self.credentialReference = credentialReference
        self.requestTimeout = requestTimeout
        self.capabilitySnapshot = capabilitySnapshot
        self.providerName = providerName
        self.secretVault = secretVault
        self.clientID = clientID ?? (try? store.ensureEventClientID())
        self.credentialRefresh = CredentialRefreshService(vault: vault)
        let configuration = urlSessionConfiguration ?? URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.httpShouldSetCookies = false
        self.session = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }

    public func item(identifier: String) throws -> RemoteItem? { try store.item(identifier: identifier) }

    private func discardTransferSecret(operationID: UUID, reference: String) {
        do {
            try secretVault.removeSecret(reference: reference)
            try store.clearUploadSessionSecretReference(operationID: operationID)
        } catch {
            // Keep the DB reference if Keychain deletion was not confirmed;
            // compaction will then retain the record for repair.
        }
    }

    public func children(parentIdentifier: String) throws -> [RemoteItem] {
        var offset = 0
        var result: [RemoteItem] = []
        repeat {
            let page = try childrenPage(parentIdentifier: parentIdentifier, offset: offset, limit: 500)
            result.append(contentsOf: page.items)
            guard let next = page.nextOffset else { break }
            offset = next
        } while true
        return result
    }

    public func childrenPage(parentIdentifier: String, offset: Int, limit: Int) throws -> DirectoryPage {
        do {
            if let snapshot = try store.currentCompleteDirectorySnapshot(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier) {
                return try store.directorySnapshotPage(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier, generation: snapshot.generation, snapshotID: snapshot.snapshotID, offset: offset, limit: limit)
            }
            let uri = try parentURI(for: parentIdentifier)
            let pageSize = max(1, min(limit, 500))
            let activeSnapshot: DirectorySnapshotDescriptor
            if offset == 0 {
                activeSnapshot = try store.activeDirectorySnapshot(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier)
                    ?? store.beginDirectorySnapshot(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier)
            } else {
                activeSnapshot = try store.activeDirectorySnapshot(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier) ?? store.beginDirectorySnapshot(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier)
            }
            let storedCursor = activeSnapshot.nextCursor.flatMap { String(data: $0, encoding: .utf8) }
            let pageNumber: Int
            if let storedCursor, storedCursor.hasPrefix("page:"), let storedPage = Int(storedCursor.dropFirst("page:".count)) {
                pageNumber = storedPage
            } else {
                pageNumber = 1
            }
            guard pageNumber > 0, pageNumber <= 2_000 else {
                throw CoreFailure(code: .quotaExceeded, retryable: false, userActionRequired: true, redactedContext: ["stage": "directory_snapshot_bound"])
            }
            var query = [
                URLQueryItem(name: "uri", value: uri),
                URLQueryItem(name: "page_size", value: String(pageSize)),
                URLQueryItem(name: "order_by", value: "name"),
                URLQueryItem(name: "order_direction", value: "asc"),
            ]
            if let cursor = storedCursor, cursor.hasPrefix("token:") {
                query.append(URLQueryItem(name: "next_page_token", value: String(cursor.dropFirst("token:".count))))
            } else {
                query.append(URLQueryItem(name: "page", value: String(pageNumber)))
            }
            let response: RemoteListDTO = try request(path: "file", method: "GET", query: query, body: nil, authenticated: true)
            var mapped: [RemoteItem] = []
            var pageIdentities: [String: String] = [:]
            for dto in response.files {
                let identifier: String
                if let existing = pageIdentities[dto.id] {
                    identifier = existing
                } else {
                    identifier = try store.itemIdentifier(forRemoteID: dto.id) ?? CloudreveIdentifier.item()
                    pageIdentities[dto.id] = identifier
                }
                mapped.append(try makeItem(dto, parentIdentifier: parentIdentifier, itemIdentifier: identifier))
            }
            let pagination = response.pagination
            let hasMore: Bool
            let localPage: DirectoryPage
            let requestUsedCursor = storedCursor?.hasPrefix("token:") == true
            if let nextToken = pagination?.nextToken {
                guard paginationContinuationIsVerified(capabilitySnapshot, usesCursor: true) else {
                    throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_capability"])
                }
                guard !nextToken.isEmpty, nextToken.utf8.count <= 64 * 1024 else {
                    throw CoreFailure(code: .unknownOutcome, retryable: true, userActionRequired: true, redactedContext: ["stage": "directory_snapshot_cursor"])
                }
                try store.appendDirectorySnapshotItems(snapshotID: activeSnapshot.snapshotID, items: mapped, nextCursor: Data("token:\(nextToken)".utf8))
                hasMore = true
            } else if requestUsedCursor {
                // In cursor mode the absence of a next token is the terminal
                // condition. Falling through to the page/total calculation
                // would restart page-number pagination after the final cursor.
                guard paginationCompletionIsVerified(capabilitySnapshot) else {
                    throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_completion_capability"])
                }
                hasMore = false
                try store.appendDirectorySnapshotItems(snapshotID: activeSnapshot.snapshotID, items: mapped, nextCursor: nil)
            } else if let total = pagination?.totalItems {
                let effectivePageSize = max(1, pagination?.pageSize ?? pageSize)
                let currentPage = max(1, pagination?.page ?? pageNumber)
                hasMore = Int64(currentPage) * Int64(effectivePageSize) < total
                if hasMore {
                    guard paginationContinuationIsVerified(capabilitySnapshot, usesCursor: false) else {
                        throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_capability"])
                    }
                }
                try store.appendDirectorySnapshotItems(snapshotID: activeSnapshot.snapshotID, items: mapped, nextCursor: hasMore ? Data("page:\(pageNumber + 1)".utf8) : nil)
            } else {
                hasMore = mapped.count >= pageSize
                if hasMore {
                    guard paginationContinuationIsVerified(capabilitySnapshot, usesCursor: false) else {
                        throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_capability"])
                    }
                }
                try store.appendDirectorySnapshotItems(snapshotID: activeSnapshot.snapshotID, items: mapped, nextCursor: hasMore ? Data("page:\(pageNumber + 1)".utf8) : nil)
            }
            if !hasMore {
                guard paginationCompletionIsVerified(capabilitySnapshot) else {
                    throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_completion_capability"])
                }
                try store.publishDirectorySnapshot(snapshotID: activeSnapshot.snapshotID)
                localPage = try store.directorySnapshotPage(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier, generation: activeSnapshot.generation, snapshotID: activeSnapshot.snapshotID, offset: offset, limit: limit)
                return DirectoryPage(items: localPage.items, nextOffset: localPage.nextOffset, generation: activeSnapshot.generation, complete: localPage.complete, snapshotID: activeSnapshot.snapshotID, expiresAt: activeSnapshot.expiresAt)
            }
            throw CoreFailure(code: .cannotSynchronize, retryable: true, userActionRequired: true, redactedContext: ["stage": "directory_snapshot_hydrating"])
        } catch let error as CoreFailure where error.code == .network {
            guard let snapshot = try store.currentCompleteDirectorySnapshot(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier) else { throw error }
            return try store.directorySnapshotPage(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier, generation: snapshot.generation, snapshotID: snapshot.snapshotID, offset: offset, limit: limit)
        }
    }

    public func trashItems() throws -> [RemoteItem] {
        guard capabilitySnapshot.canTrash else { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
        return try store.trashItems()
    }

    public func content(identifier: String, expectedVersion: Data?) throws -> Data {
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-read-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        _ = try fetchContent(identifier: identifier, expectedVersion: expectedVersion, to: temporaryURL)
        return try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
    }

    public func fetchContent(identifier: String, expectedVersion: Data?, to destination: URL) throws -> RemoteItem {
        var stage = "lookup_item"
        do {
            guard let stored = try store.item(identifier: identifier), stored.remoteID != nil else { throw CoreFailure(code: .notFound, retryable: false) }
            guard stored.canRead else { throw CoreFailure(code: .permissionDenied, retryable: false, userActionRequired: true) }
            if let expectedVersion, expectedVersion != stored.version.content { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }
            stage = "refresh_remote_metadata"
            let current = expectedVersion == nil ? try fetchRemoteItem(fallback: stored) : stored
            if current != stored {
                try commitFetchedMetadataChange(old: stored, new: current)
            }
            guard current.canRead else { throw CoreFailure(code: .permissionDenied, retryable: false, userActionRequired: true) }
            stage = "request_download_url"
            let currentURI = try canonicalRemoteURI(current.uri)
            let entity = current.remoteVersion?.isEmpty == false ? current.remoteVersion : nil
            let url = try signedDownloadURL(uri: currentURI, entity: entity)
            stage = "download-url"
            do {
                try downloadWithoutBearer(url: url, to: destination, expectedSize: current.size)
            } catch let error as DownloadHTTPError where error.statusCode == 404 && entity != nil {
                logger.warning("download.url_retry_without_entity item=\(identifier, privacy: .public)")
                let fallbackURL = try signedDownloadURL(uri: currentURI, entity: nil)
                try downloadWithoutBearer(url: fallbackURL, to: destination, expectedSize: current.size)
            }
            stage = "verify_remote_version"
            let refreshed = try fetchRemoteItem(fallback: current)
            if refreshed != current {
                try commitFetchedMetadataChange(old: current, new: refreshed)
            }
            guard refreshed.version.content == current.version.content else {
                try? FileManager.default.removeItem(at: destination)
                throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true)
            }
            logger.info("download.succeeded item=\(identifier, privacy: .public) bytes=\(current.size, privacy: .public)")
            return refreshed
        } catch let error as DownloadHTTPError {
            let failure = CoreFailure(code: .network, retryable: true, redactedContext: ["http-status": String(error.statusCode)])
            logger.error("download.failed item=\(identifier, privacy: .public) stage=\(stage, privacy: .public) code=\(failure.code.rawValue, privacy: .public) retryable=\(failure.retryable, privacy: .public) correlation=\(failure.correlationID.uuidString, privacy: .public)")
            throw failure
        } catch {
            if let failure = error as? CoreFailure {
                logger.error("download.failed item=\(identifier, privacy: .public) stage=\(stage, privacy: .public) code=\(failure.code.rawValue, privacy: .public) retryable=\(failure.retryable, privacy: .public) correlation=\(failure.correlationID.uuidString, privacy: .public)")
            } else {
                logger.error("download.failed item=\(identifier, privacy: .public) stage=\(stage, privacy: .public) error=unclassified")
            }
            throw error
        }
    }

    public func create(template: RemoteItem, content: Data?, replayKey: String) throws -> RemoteItem {
        try requireOperation("create")
        if let content {
            try requireOperation("content")
            if content.isEmpty { try requireOperation("zero_byte") }
        } else if template.kind == .file {
            try requireOperation("zero_byte")
        }
        try validateName(template.name)
        guard template.canWrite else { throw CoreFailure(code: .permissionDenied, retryable: false, userActionRequired: true) }
        let parentURI = try parentURI(for: template.parentIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue)
        let targetURI = try CloudreveRemoteURI.append(parentURI, name: template.name)
        if let content, !content.isEmpty { return try uploadFile(uri: targetURI, content: content, previous: nil, itemIdentifier: template.itemIdentifier, parentIdentifier: template.parentIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue) }
        let dto: RemoteFileDTO = try request(path: "file/create", method: "POST", query: [], body: ["uri": targetURI, "type": template.kind == .folder ? "folder" : "file", "err_on_conflict": true], authenticated: true)
        return try makeItem(dto, parentIdentifier: template.parentIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue, itemIdentifier: template.itemIdentifier)
    }

    public func modify(item: RemoteItem, expectedVersion: Data?, changedFields: NSFileProviderItemFields, content: Data?, replayKey: String) throws -> RemoteItem {
        let previousVersion: String?
        if changedFields.contains(.contents) {
            try requireOperation("content")
            if content?.isEmpty == true { try requireOperation("zero_byte") }
            guard let previous = try store.item(identifier: item.itemIdentifier)?.remoteVersion, !previous.isEmpty else {
                throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "missing_previous_version"])
            }
            previousVersion = previous
        } else {
            previousVersion = nil
        }
        if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) { try requireOperation("metadata_move") }
        guard let current = try store.item(identifier: item.itemIdentifier) else { throw CoreFailure(code: .notFound, retryable: false) }
        guard current.canWrite else { throw CoreFailure(code: .permissionDenied, retryable: false, userActionRequired: true) }
        if let expectedVersion, expectedVersion != current.version.content { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }
        var result = current
        if changedFields.contains(.contents) {
            guard let content else { throw CoreFailure(code: .unsupportedMetadata, retryable: false) }
            if content.isEmpty {
                result = try updateEmptyContent(uri: current.uri, previous: previousVersion, itemIdentifier: current.itemIdentifier, parentIdentifier: current.parentIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue)
            } else {
                result = try uploadFile(uri: current.uri, content: content, previous: previousVersion, itemIdentifier: current.itemIdentifier, parentIdentifier: current.parentIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue)
            }
        }
        if changedFields.contains(.filename) {
            try validateName(item.name)
            let dto: RemoteFileDTO = try request(path: "file/rename", method: "POST", query: [], body: ["uri": result.uri, "new_name": item.name], authenticated: true)
            result = try makeItem(dto, parentIdentifier: result.parentIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue, itemIdentifier: result.itemIdentifier)
        }
        if changedFields.contains(.parentItemIdentifier) {
            let destination = try parentURI(for: item.parentIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue)
            let _: EmptyResponse = try request(path: "file/move", method: "POST", query: [], body: ["uris": [result.uri], "dst": destination, "copy": false], authenticated: true)
            result.parentIdentifier = item.parentIdentifier
            result.uri = try CloudreveRemoteURI.append(destination, name: result.name)
        }
        return result
    }

    public func trash(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem {
        try requireOperation("trash")
        guard let current = try store.item(identifier: item.itemIdentifier) else { throw CoreFailure(code: .notFound, retryable: false) }
        guard current.canTrash else { throw CoreFailure(code: .permissionDenied, retryable: false, userActionRequired: true) }
        if let expectedVersion, expectedVersion != current.version.content { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }
        let _: EmptyResponse = try request(path: "file", method: "DELETE", query: [], body: ["uris": [current.uri], "skip_soft_delete": false], authenticated: true)
        var trashed = current
        trashed.trashed = true
        trashed.trashOriginalParentIdentifier = current.parentIdentifier
        trashed.parentIdentifier = NSFileProviderItemIdentifier.trashContainer.rawValue
        return trashed
    }

    public func restore(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem {
        try requireOperation("trash")
        guard let current = try store.item(identifier: item.itemIdentifier) else { throw CoreFailure(code: .notFound, retryable: false) }
        guard capabilitySnapshot.canTrash else { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
        guard current.trashed else { throw CoreFailure(code: .cannotSynchronize, retryable: false, userActionRequired: true) }
        guard current.canTrash else { throw CoreFailure(code: .permissionDenied, retryable: false, userActionRequired: true) }
        if let expectedVersion, expectedVersion != current.version.content { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }
        let _: EmptyResponse = try request(path: "file/restore", method: "POST", query: [], body: ["uris": [current.uri]], authenticated: true)
        var restored = current
        restored.trashed = false
        restored.parentIdentifier = current.trashOriginalParentIdentifier ?? item.parentIdentifier
        restored.trashOriginalParentIdentifier = nil
        return restored
    }

    public func delete(identifier: String, expectedVersion: Data?, recursive: Bool) throws {
        try requireOperation("purge")
        guard let current = try store.item(identifier: identifier) else { return }
        guard current.canDelete else { throw CoreFailure(code: .permissionDenied, retryable: false, userActionRequired: true) }
        if let expectedVersion, expectedVersion != current.version.content { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }
        if current.kind == .folder && !recursive {
            let children = try children(parentIdentifier: identifier)
            if !children.isEmpty { throw CoreFailure(code: .directoryNotEmpty, retryable: false) }
        }
        guard current.trashed else { throw CoreFailure(code: .cannotSynchronize, retryable: false, userActionRequired: true) }
        do {
            let _: EmptyResponse = try request(path: "file", method: "DELETE", query: [], body: ["uris": [current.uri], "skip_soft_delete": true], authenticated: true)
        } catch let failure as CoreFailure where failure.code == .notFound {
            // Purge is idempotent once the remote trash entry has already
            // disappeared.
        }
        var tombstone = current
        tombstone.tombstone = true
    }

    private func parentURI(for identifier: String) throws -> String {
        if identifier == NSFileProviderItemIdentifier.rootContainer.rawValue { return rootURI }
        guard let storedDomain = try store.domain(identifier: domainIdentifier),
              let accountID = URLComponents(string: storedDomain.rootURI)?.user,
              !storedDomain.rootRemoteID.isEmpty else {
            throw CoreFailure(code: .rootUnavailable, retryable: false, userActionRequired: true)
        }
        let resolver = ParentResolver(
            store: store,
            rootURI: storedDomain.rootURI,
            accountID: accountID,
            rootIdentifier: storedDomain.rootRemoteID
        )
        do {
            let item = try resolver.resolve(
                parentIdentifier: identifier,
                // A provider item identifier is intentionally opaque and is
                // not a Cloudreve remote ID. Never send it to file/info as an
                // id; recovery can proceed from a stored item's URI or fail
                // closed as retryable when that mapping is absent.
                hydrate: { nil },
                hydrateParent: { [self] uri in try hydrateFolder(uri: uri, accountID: accountID) },
                hydrateParentWithIdentifier: { [self] uri, expectedIdentifier in
                    try hydrateFolder(uri: uri, accountID: accountID, expectedIdentifier: expectedIdentifier)
                }
            )
            return try canonicalRemoteURI(item.uri)
        } catch let error as CoreFailure where error.code == .notFound {
            throw CoreFailure(code: .network, retryable: true, userActionRequired: true, redactedContext: ["stage": "parent_hydration"])
        } catch let error as ParentResolutionError {
            switch error {
            case .missing, .invalidIdentifier:
                throw CoreFailure(code: .notFound, retryable: false, userActionRequired: true)
            case .outsideScope:
                throw CoreFailure(code: .rootUnavailable, retryable: false, userActionRequired: true)
            case .retryable:
                throw CoreFailure(code: .network, retryable: true, userActionRequired: true, redactedContext: ["stage": "parent_hydration"])
            }
        }
    }

    private func parentURIAsync(for identifier: String, context: FileProviderOperationContext) async throws -> String {
        try context.cancellation.throwIfCancelled()
        if identifier == NSFileProviderItemIdentifier.rootContainer.rawValue { return rootURI }
        guard let item = try store.item(identifier: identifier), item.kind == .folder else {
            throw CoreFailure(code: .network, retryable: true, userActionRequired: true, redactedContext: ["stage": "parent_mapping_missing"])
        }
        return try canonicalRemoteURI(item.uri)
    }

    private func parentIdentifierForRemoteURI(_ uri: String, fallback: String?) throws -> String {
        guard let parentURI = CloudreveRemoteURI.parent(uri) else {
            throw CoreFailure(code: .rootUnavailable, retryable: false, userActionRequired: true)
        }
        if parentURI == rootURI {
            return NSFileProviderItemIdentifier.rootContainer.rawValue
        }
        if let identifier = try store.itemIdentifier(forRemoteURI: parentURI) {
            return identifier
        }
        if let fallback,
           let item = try store.item(identifier: fallback),
           (try? canonicalRemoteURI(item.uri)) == parentURI {
            return fallback
        }
        guard let storedDomain = try store.domain(identifier: domainIdentifier),
              let accountID = URLComponents(string: storedDomain.rootURI)?.user,
              let parent = try hydrateFolder(uri: parentURI, accountID: accountID) else {
            throw CoreFailure(code: .network, retryable: true, userActionRequired: true, redactedContext: ["stage": "remote_parent_hydration"])
        }
        return parent.itemIdentifier
    }

    private func parentIdentifierForRemoteURIAsync(
        _ uri: String,
        fallback: String?,
        context: FileProviderOperationContext
    ) async throws -> String {
        try context.cancellation.throwIfCancelled()
        guard let parentURI = CloudreveRemoteURI.parent(uri) else {
            throw CoreFailure(code: .rootUnavailable, retryable: false, userActionRequired: true)
        }
        if parentURI == rootURI {
            return NSFileProviderItemIdentifier.rootContainer.rawValue
        }
        if let identifier = try store.itemIdentifier(forRemoteURI: parentURI) {
            return identifier
        }
        if let fallback,
           let item = try store.item(identifier: fallback),
           (try? canonicalRemoteURI(item.uri)) == parentURI {
            return fallback
        }
        guard let storedDomain = try store.domain(identifier: domainIdentifier),
              let accountID = URLComponents(string: storedDomain.rootURI)?.user,
              let parent = try await hydrateFolderAsync(uri: parentURI, accountID: accountID, depth: 0, context: context) else {
            throw CoreFailure(code: .network, retryable: true, userActionRequired: true, redactedContext: ["stage": "remote_parent_hydration"])
        }
        return parent.itemIdentifier
    }

    /// Resolve a missing folder and its ancestors through the authenticated
    /// metadata endpoint. The recursion is deliberately bounded and only
    /// accepts folders inside this Domain's root scope.
    private func hydrateFolder(uri: String, accountID: String, depth: Int = 0, expectedIdentifier: String? = nil) throws -> RemoteItem? {
        let dto: RemoteFileDTO = try request(
            path: "file/info",
            method: "GET",
            query: [URLQueryItem(name: "uri", value: uri), URLQueryItem(name: "extended", value: "true")],
            body: nil,
            authenticated: true
        )
        return try hydrateFolder(dto: dto, accountID: accountID, depth: depth, expectedIdentifier: expectedIdentifier)
    }

    private func hydrateFolder(dto: RemoteFileDTO, accountID: String, depth: Int, expectedIdentifier: String? = nil) throws -> RemoteItem? {
        guard depth < 32, dto.type == 1, !dto.id.isEmpty else { return nil }
        guard dto.id != (try store.domain(identifier: domainIdentifier)?.rootRemoteID ?? "") else { return nil }
        let normalized = try CloudreveRemoteURI.canonical(dto.path, accountID: accountID)
        guard CloudreveRemoteURI.isWithin(normalized, root: rootURI),
              let parentURI = CloudreveRemoteURI.parent(normalized) else {
            throw CoreFailure(code: .rootUnavailable, retryable: false, userActionRequired: true)
        }
        let parentIdentifier: String
        if parentURI == rootURI {
            parentIdentifier = NSFileProviderItemIdentifier.rootContainer.rawValue
        } else {
            guard let parent = try hydrateFolder(uri: parentURI, accountID: accountID, depth: depth + 1) else { return nil }
            parentIdentifier = parent.itemIdentifier
        }
        let mappedIdentifier = try store.itemIdentifier(forRemoteID: dto.id)
        if let expectedIdentifier, let mappedIdentifier, mappedIdentifier != expectedIdentifier {
            throw ParentResolutionError.retryable
        }
        let identifier = expectedIdentifier ?? mappedIdentifier ?? CloudreveIdentifier.item()
        let item = try makeItem(dto, parentIdentifier: parentIdentifier, itemIdentifier: identifier)
        try store.insertItem(item)
        return item
    }

    private func hydrateFolderAsync(
        uri: String,
        accountID: String,
        depth: Int,
        context: FileProviderOperationContext
    ) async throws -> RemoteItem? {
        try context.cancellation.throwIfCancelled()
        guard depth < 32 else { return nil }
        let dto: RemoteFileDTO = try await requestAsync(
            path: "file/info",
            method: "GET",
            query: [URLQueryItem(name: "uri", value: uri), URLQueryItem(name: "extended", value: "true")],
            body: nil,
            authenticated: true,
            context: context
        )
        guard dto.type == 1, !dto.id.isEmpty,
              dto.id != (try store.domain(identifier: domainIdentifier)?.rootRemoteID ?? "") else {
            return nil
        }
        let normalized = try CloudreveRemoteURI.canonical(dto.path, accountID: accountID)
        guard CloudreveRemoteURI.isWithin(normalized, root: rootURI),
              let parentURI = CloudreveRemoteURI.parent(normalized) else { return nil }
        let parentIdentifier: String
        if parentURI == rootURI {
            parentIdentifier = NSFileProviderItemIdentifier.rootContainer.rawValue
        } else {
            guard let parent = try await hydrateFolderAsync(uri: parentURI, accountID: accountID, depth: depth + 1, context: context) else { return nil }
            parentIdentifier = parent.itemIdentifier
        }
        let identifier = try store.itemIdentifier(forRemoteID: dto.id) ?? CloudreveIdentifier.item()
        let item = try makeItem(dto, parentIdentifier: parentIdentifier, itemIdentifier: identifier)
        try store.insertItem(item)
        return item
    }

    private func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { throw CoreFailure(code: .invalidName, retryable: false, userActionRequired: true) }
    }

    private func commitFetchedMetadataChange(old: RemoteItem, new: RemoteItem) throws {
        _ = try store.commitProviderChange(
            item: new,
            oldParentIdentifier: old.parentIdentifier,
            newParentIdentifier: new.parentIdentifier,
            kind: "remote_metadata_refresh",
            origin: "fetch_contents"
        )
    }

    private func validateURI(_ uri: String) throws {
        guard CloudreveRemoteURI.isWithin(uri, root: rootURI) else { throw CoreFailure(code: .rootUnavailable, retryable: false, userActionRequired: true) }
    }

    private func canonicalRemoteURI(_ value: String) throws -> String {
        guard let rootComponents = URLComponents(string: rootURI), let accountID = rootComponents.user else {
            throw CoreFailure(code: .rootUnavailable, retryable: false, userActionRequired: true)
        }
        do {
            let canonical = try CloudreveRemoteURI.canonical(value, accountID: accountID)
            try validateURI(canonical)
            return canonical
        } catch let error as CoreFailure {
            throw error
        } catch {
            throw CoreFailure(code: .rootUnavailable, retryable: false, userActionRequired: true)
        }
    }

    private func boundedUploadURLs(_ values: [String], allowRelative: Bool = false) throws -> [String] {
        guard values.count <= 1_024 else { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
        for value in values where !value.isEmpty {
            if value.hasPrefix("/") {
                guard allowRelative else { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
            } else {
                _ = try safeExternalURL(value)
            }
        }
        guard values.reduce(0, { $0 + $1.utf8.count }) <= 64 * 1024 else { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
        return values
    }

    private func requireOperation(_ operation: String) throws {
        let verified: Bool
        switch operation {
        case "create": verified = capabilitySnapshot.stableItemIdentity == .verified && capabilitySnapshot.stableRootIdentity == .verified && capabilitySnapshot.operations.collisionSafeCreate == .verified
        case "content": verified = capabilitySnapshot.stableItemIdentity == .verified && capabilitySnapshot.stableRootIdentity == .verified && capabilitySnapshot.operations.conditionalModify == .verified && capabilitySnapshot.canWrite(provider: providerName)
        case "zero_byte": verified = capabilitySnapshot.canWriteZeroByte(provider: providerName)
        case "metadata_move": verified = capabilitySnapshot.stableItemIdentity == .verified && capabilitySnapshot.stableRootIdentity == .verified && capabilitySnapshot.conditionalMetadataMutation == .verified && capabilitySnapshot.operations.metadataMove == .verified
        case "trash": verified = capabilitySnapshot.canTrash
        case "purge": verified = capabilitySnapshot.canPurge
        default: verified = false
        }
        guard verified else { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["operation": operation]) }
    }

    private func updateEmptyContent(uri: String, previous: String?, itemIdentifier: String, parentIdentifier: String) throws -> RemoteItem {
        var components = URLComponents(url: origin.appendingPathComponent("api/v4/file/content"), resolvingAgainstBaseURL: false)
        var query = [URLQueryItem(name: "uri", value: uri)]
        if let previous { query.append(URLQueryItem(name: "previous", value: previous)) }
        components?.queryItems = query
        guard let url = components?.url else { throw CoreFailure(code: .network, retryable: true) }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data()
        guard let credential = try vault.read(reference: credentialReference) else { throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true) }
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try perform(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw CoreFailure(code: .network, retryable: true) }
        let envelope = try JSONDecoder().decode(APIEnvelope<RemoteFileDTO>.self, from: data)
        guard envelope.code == 0, let dto = envelope.data else { throw CoreFailure(code: .unknownOutcome, retryable: false) }
        return try makeItem(dto, parentIdentifier: parentIdentifier, itemIdentifier: itemIdentifier)
    }

    private func uploadFile(uri: String, content: Data, previous: String?, itemIdentifier: String, parentIdentifier: String) throws -> RemoteItem {
        let fingerprint = Data(SHA256.hash(data: content + Data((previous ?? "").utf8)))
        let operationID = stableOperationID("\(itemIdentifier)|\(previous ?? "create")|\(fingerprint.base64EncodedString())")
        var session = try store.uploadSession(operationID: operationID)
        if let existing = session,
           existing.fingerprint == fingerprint,
           (existing.state == "completed" || existing.state == "verifying") {
            let result = try fetchRemoteByURI(uri: uri, fallbackIdentifier: itemIdentifier, parentIdentifier: parentIdentifier)
            var verified = existing
            verified.state = "completed"
            try store.saveUploadSession(verified)
            if let reference = verified.secretReference { discardTransferSecret(operationID: operationID, reference: reference) }
            return result
        }
        var cache: UploadCredentialCache?
        if let existing = session, existing.state != "abandoned", existing.fingerprint == fingerprint, existing.expiresAt.map({ $0 > Date() }) ?? true, let reference = existing.secretReference, let encoded = try secretVault.readSecret(reference: reference), let data = Data(base64Encoded: encoded) {
            cache = try? JSONDecoder().decode(UploadCredentialCache.self, from: data)
        } else if let existing = session, existing.fingerprint != fingerprint {
            var abandoned = existing
            abandoned.state = "abandoned"
            try store.saveUploadSession(abandoned)
            if let secretReference = existing.secretReference { discardTransferSecret(operationID: operationID, reference: secretReference) }
            session = nil
        }
        if cache == nil {
            var uploadBody: [String: Any] = ["uri": uri, "size": content.count, "policy_id": ""]
            if let previous {
                uploadBody["previous"] = previous
                uploadBody["entity_type"] = "version"
            }
            let credential: UploadCredentialDTO = try request(path: "file/upload", method: "PUT", query: [], body: uploadBody, authenticated: true)
            guard isOpaqueTransferComponent(credential.sessionID) else {
                throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "session_id"])
            }
            let provider = credential.storagePolicy?.type?.lowercased() ?? providerName.lowercased()
            guard provider.caseInsensitiveCompare(providerName) == .orderedSame else { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
            let uploadURLs = try boundedUploadURLs(credential.uploadURLs ?? [], allowRelative: provider == "remote")
            let expiresAt = credential.expires > 0 ? Date(timeIntervalSince1970: TimeInterval(credential.expires)) : nil
            let secretReference = "transfer-\(operationID.uuidString)"
            let newCache = UploadCredentialCache(sessionID: credential.sessionID, credential: credential.credential, uploadPolicy: credential.uploadPolicy, mimeType: credential.mimeType, uploadURLs: uploadURLs, callbackSecret: credential.callbackSecret, completeURL: credential.completeURL, provider: provider, expiresAt: expiresAt)
            try secretVault.writeSecret(JSONEncoder().encode(newCache).base64EncodedString(), reference: secretReference)
            guard credential.chunkSize > 0, provider == "upyun" || credential.chunkSize <= 8 * 1024 * 1024 else {
                discardTransferSecret(operationID: operationID, reference: secretReference)
                throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "chunk_size"])
            }
            let descriptors = provider == "upyun"
                ? [UploadPartDescriptor(index: 0, offset: 0, length: content.count)]
                : planParts(size: content.count, chunkSize: Int(credential.chunkSize))
            let parts = descriptors.map { descriptor in
                let sourceHash = provider == "upyun"
                    ? Data(SHA256.hash(data: content))
                    : Data(SHA256.hash(data: content[descriptor.offset..<(descriptor.offset + descriptor.length)]))
                return UploadPartCheckpoint(index: descriptor.index, offset: Int64(descriptor.offset), length: Int64(descriptor.length), sourceHash: sourceHash)
            }
            let checkpointChunkSize = provider == "upyun" ? max(1, Int64(content.count)) : credential.chunkSize
            session = UploadSessionCheckpoint(operationID: operationID, remoteSessionReference: credential.sessionID, secretReference: secretReference, fingerprint: fingerprint, provider: provider, chunkSize: checkpointChunkSize, expiresAt: expiresAt, state: "active", parts: parts)
            cache = newCache
            try store.saveUploadSession(session!)
        }
        guard var active = session, let cache else { throw CoreFailure(code: .unknownOutcome, retryable: false) }
        guard isOpaqueTransferComponent(cache.sessionID) else {
            throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "session_id"])
        }
        guard active.fingerprint == fingerprint else { throw CoreFailure(code: .awaitingSourceReplay, retryable: false, userActionRequired: true) }
        for index in active.parts.indices {
            let part = active.parts[index]
            let start = Int(part.offset)
            let end = min(content.count, start + Int(part.length))
            let data = content[start..<end]
            let provider = cache.provider.lowercased()
            let chunkData = Data(data)
            let hash = provider == "upyun" ? Data(SHA256.hash(data: content)) : Data(SHA256.hash(data: chunkData))
            if part.state == "completed" {
                guard hash == part.sourceHash else { throw CoreFailure(code: .awaitingSourceReplay, retryable: false, userActionRequired: true) }
                continue
            }
            let etag: String?
            if provider == "qiniu" {
                guard let uploadURL = cache.uploadURLs.first, !uploadURL.isEmpty,
                      let credential = cache.credential else {
                    throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "qiniu_credentials"])
                }
                let baseURL = try safeExternalURL(uploadURL)
                etag = try uploadQiniuPart(baseURL: baseURL, credential: credential, index: part.index, data: chunkData)
            } else if provider == "upyun" {
                guard part.index == 0,
                      let uploadURL = cache.uploadURLs.first, !uploadURL.isEmpty,
                      let policy = cache.uploadPolicy,
                      let credential = cache.credential else {
                    throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "upyun_credentials"])
                }
                let url = try safeExternalURL(uploadURL)
                try uploadUpyunPart(url: url, policy: policy, authorization: credential, mimeType: cache.mimeType, data: chunkData)
                etag = nil
            } else if provider == "remote", let uploadURL = cache.uploadURLs.first, !uploadURL.isEmpty, !uploadURL.hasPrefix("/") {
                guard let credential = cache.credential else {
                    throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "remote_credentials"])
                }
                try uploadRemotePart(url: try safeExternalURL(uploadURL), credential: credential, index: part.index, data: chunkData)
                etag = nil
            } else {
                let uploadIndex = provider == "onedrive" ? 0 : part.index
                if ["s3", "oss", "cos", "ks3", "obs", "onedrive"].contains(provider) {
                    guard let uploadURL = cache.uploadURLs[safe: uploadIndex], !uploadURL.isEmpty else {
                        throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "missing-upload-url"])
                    }
                    let url = try safeExternalURL(uploadURL)
                    let range = provider == "onedrive" && part.length > 0 ? "bytes \(part.offset)-\(part.offset + part.length - 1)/\(content.count)" : nil
                    etag = try uploadSignedPart(url: url, data: chunkData, contentRange: range)
                } else {
                    etag = try uploadRelayPart(sessionID: cache.sessionID, index: part.index, data: chunkData)
                }
            }
            active.parts[index].etag = etag
            active.parts[index].sourceHash = hash
            active.parts[index].state = "completed"
            active.parts[index].attempt += 1
            try store.saveUploadSession(active)
        }
        let provider = cache.provider.lowercased()
        if provider == "qiniu" {
            guard let uploadURL = cache.uploadURLs.first, !uploadURL.isEmpty,
                  let credential = cache.credential else {
                throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "qiniu_credentials"])
            }
            try completeQiniuUpload(baseURL: try safeExternalURL(uploadURL), credential: credential, parts: active.parts, mimeType: cache.mimeType)
        } else if let completeURL = cache.completeURL, !completeURL.isEmpty, ["oss", "cos", "s3", "ks3", "obs"].contains(provider) {
            try completeExternalUpload(urlString: completeURL, provider: cache.provider, parts: active.parts)
        }
        let policy = provider.isEmpty ? providerName.lowercased() : provider
        let needsCallback = ["s3", "cos", "ks3", "onedrive"].contains(policy)
        if needsCallback {
            guard let secret = cache.callbackSecret, isOpaqueTransferComponent(secret, maximumLength: 512) else {
                throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true)
            }
            let method = policy == "onedrive" ? "POST" : "GET"
            _ = try requestNoContent(path: "callback/\(policy)/\(cache.sessionID)/\(secret)", method: method, authenticated: false)
        } else if (policy != "local" && policy != "remote" && policy != "qiniu" && policy != "upyun") {
            throw CoreFailure(code: .unknownOutcome, retryable: false, userActionRequired: true)
        }
        active.state = "verifying"
        try store.saveUploadSession(active)
        let result = try fetchRemoteByURI(uri: uri, fallbackIdentifier: itemIdentifier, parentIdentifier: parentIdentifier)
        active.state = "completed"
        try store.saveUploadSession(active)
        if let secretReference = active.secretReference { discardTransferSecret(operationID: operationID, reference: secretReference) }
        return result
    }

    private func fetchRemoteByURI(uri: String, fallbackIdentifier: String, parentIdentifier: String) throws -> RemoteItem {
        let dto: RemoteFileDTO = try request(path: "file/info", method: "GET", query: [URLQueryItem(name: "uri", value: uri), URLQueryItem(name: "extended", value: "true")], body: nil, authenticated: true)
        return try makeItem(dto, parentIdentifier: parentIdentifier, itemIdentifier: fallbackIdentifier)
    }

    private func uploadSignedPart(url: URL, data: Data, contentRange: String? = nil, authorization: String? = nil) throws -> String? {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        if let contentRange { request.setValue(contentRange, forHTTPHeaderField: "Content-Range") }
        if let authorization {
            guard isSafeTransferValue(authorization) else {
                throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true)
            }
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = data
        let (_, response) = try performOnce(request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw CoreFailure(code: .network, retryable: true) }
        return response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private func uploadRemotePart(url: URL, credential: String, index: Int, data: Data) throws {
        guard isSafeTransferValue(credential) else {
            throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query = components?.queryItems ?? []
        query.append(URLQueryItem(name: "chunk", value: String(index)))
        components?.queryItems = query
        guard let target = components?.url else {
            throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true)
        }
        var request = URLRequest(url: target, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        request.setValue(credential, forHTTPHeaderField: "Authorization")
        request.httpBody = data
        let (body, response) = try performOnce(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CoreFailure(code: .network, retryable: true)
        }
        if let envelope = try? JSONDecoder().decode(APIEnvelope<EmptyResponse>.self, from: body), envelope.code != 0 {
            throw mapAPIError(envelope.code, message: envelope.msg)
        }
    }

    private func uploadQiniuPart(baseURL: URL, credential: String, index: Int, data: Data) throws -> String {
        guard isSafeTransferValue(credential) else {
            throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true)
        }
        let url = baseURL.appendingPathComponent(String(index + 1))
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        request.setValue("UpToken \(credential)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        let (body, response) = try performOnce(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CoreFailure(code: .network, retryable: true)
        }
        guard let value = try? JSONDecoder().decode(QiniuChunkResponse.self, from: body),
              let etag = value.etag,
              isSafeTransferValue(etag, maximumLength: 1024) else {
            throw CoreFailure(code: .unknownOutcome, retryable: true, userActionRequired: true, redactedContext: ["stage": "qiniu_part_response"])
        }
        return etag
    }

    private func completeQiniuUpload(baseURL: URL, credential: String, parts: [UploadPartCheckpoint], mimeType: String?) throws {
        guard isSafeTransferValue(credential) else {
            throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true)
        }
        let completedParts = parts.sorted { $0.index < $1.index }.compactMap { part -> [String: Any]? in
            guard let etag = part.etag, isSafeTransferValue(etag, maximumLength: 1024) else { return nil }
            return ["etag": etag, "partNumber": part.index + 1]
        }
        guard completedParts.count == parts.count else {
            throw CoreFailure(code: .unknownOutcome, retryable: true, userActionRequired: true, redactedContext: ["stage": "qiniu_missing_etag"])
        }
        var payload: [String: Any] = ["parts": completedParts]
        if let mimeType, isSafeTransferValue(mimeType, maximumLength: 256) {
            payload["mimeType"] = mimeType
        }
        var request = URLRequest(url: baseURL, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("UpToken \(credential)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try performOnce(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CoreFailure(code: .network, retryable: true)
        }
    }

    private func makeUpyunMultipartBody(data: Data, policy: String, authorization: String, mimeType: String?) throws -> (Data, String) {
        guard isSafeTransferValue(policy), isSafeTransferValue(authorization) else {
            throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true)
        }
        let boundary = "NimbusSync-\(UUID().uuidString)"
        let mime = (mimeType.flatMap { isSafeTransferValue($0, maximumLength: 256) ? $0 : nil }) ?? "application/octet-stream"
        var body = Data()
        func append(_ value: String) { body.append(contentsOf: value.utf8) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"policy\"\r\n\r\n\(policy)\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"authorization\"\r\n\r\n\(authorization)\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"file\"\r\nContent-Type: \(mime)\r\n\r\n")
        body.append(data)
        let contentTypeField = mimeType.map { _ in "--\(boundary)\r\nContent-Disposition: form-data; name=\"content-type\"\r\n\r\n\(mime)\r\n" } ?? ""
        let footer = "\r\n\(contentTypeField)--\(boundary)--\r\n"
        append(footer)
        return (body, boundary)
    }

    private func uploadUpyunPart(url: URL, policy: String, authorization: String, mimeType: String?, data: Data) throws {
        let (body, boundary) = try makeUpyunMultipartBody(data: data, policy: policy, authorization: authorization, mimeType: mimeType)
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = body
        let (_, response) = try performOnce(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CoreFailure(code: .network, retryable: true)
        }
    }

    private func uploadRelayPart(sessionID: String, index: Int, data: Data) throws -> String? {
        _ = try requestNoContent(path: "file/upload/\(sessionID)/\(index)", method: "POST", authenticated: true, body: data)
        return nil
    }

    private func completeExternalUpload(urlString: String, provider: String, parts: [UploadPartCheckpoint]) throws {
        let url = try safeExternalURL(urlString)
        let xml = "<CompleteMultipartUpload>" + parts.sorted { $0.index < $1.index }.compactMap { part in
            guard let etag = part.etag else { return nil }
            let escaped = etag.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
            return "<Part><PartNumber>\(part.index + 1)</PartNumber><ETag>\(escaped)</ETag></Part>"
        }.joined() + "</CompleteMultipartUpload>"
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        switch provider.lowercased() {
        case "oss":
            request.setValue("true", forHTTPHeaderField: "x-oss-forbid-overwrite")
            request.setValue("yes", forHTTPHeaderField: "x-oss-complete-all")
            request.setValue("0", forHTTPHeaderField: "Content-Length")
            request.httpBody = Data()
        case "cos":
            request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            request.setValue("true", forHTTPHeaderField: "x-cos-forbid-overwrite")
            request.httpBody = Data(xml.utf8)
        case "s3", "ks3", "obs":
            request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(xml.utf8)
        default:
            throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true)
        }
        let (_, response) = try perform(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw CoreFailure(code: .network, retryable: true) }
    }

    private func requestNoContent(path: String, method: String, authenticated: Bool, body: Data? = nil) throws -> (Data, URLResponse) {
        let url = origin.appendingPathComponent("api/v4").appendingPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = method
        if let body { request.httpBody = body; request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type"); request.setValue(String(body.count), forHTTPHeaderField: "Content-Length") }
        if authenticated {
            guard let credential = try vault.read(reference: credentialReference) else { throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true) }
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        }
        var result = try perform(request)
        guard let response = result.1 as? HTTPURLResponse else { throw CoreFailure(code: .network, retryable: true) }
        guard (200..<300).contains(response.statusCode) else { throw mapHTTPStatus(response.statusCode) }
        if var envelope = try? JSONDecoder().decode(APIEnvelope<EmptyResponse>.self, from: result.0) {
            if authenticated, isAuthenticationAPIError(code: envelope.code, message: envelope.msg) {
                let refreshed = try refreshCredentialSynchronously()
                request.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
                result = try performOnce(request)
                guard let retryResponse = result.1 as? HTTPURLResponse, (200..<300).contains(retryResponse.statusCode) else {
                    throw mapHTTPStatus((result.1 as? HTTPURLResponse)?.statusCode ?? 0)
                }
                envelope = try JSONDecoder().decode(APIEnvelope<EmptyResponse>.self, from: result.0)
            }
            guard envelope.code == 0 else { throw mapAPIError(envelope.code, message: envelope.msg) }
        }
        return result
    }

    private func fetchRemoteItem(fallback: RemoteItem) throws -> RemoteItem {
        let uri = try canonicalRemoteURI(fallback.uri)
        let dto: RemoteFileDTO = try request(path: "file/info", method: "GET", query: [URLQueryItem(name: "uri", value: uri), URLQueryItem(name: "extended", value: "true")], body: nil, authenticated: true)
        let normalized = try canonicalRemoteURI(dto.path)
        let parent = try parentIdentifierForRemoteURI(normalized, fallback: fallback.parentIdentifier)
        return try makeItem(dto, parentIdentifier: parent, itemIdentifier: fallback.itemIdentifier)
    }

    private func makeItem(_ dto: RemoteFileDTO, parentIdentifier: String, itemIdentifier: String? = nil) throws -> RemoteItem {
        let normalizedURI = try canonicalRemoteURI(dto.path)
        // updated_at is metadata evidence, not a content version. Keep a
        // stable placeholder for read-only projection when the server omits
        // primary_entity, and never expose file writes in that state.
        let contentVersion = RemoteContentVersionPolicy.resolve(primaryEntity: dto.primaryEntity, stableEntityID: dto.id)
        let hasReliableContentRevision = contentVersion.reliable
        let contentRevision = contentVersion.value
        let kind: RemoteItemKind = dto.type == 1 ? .folder : (dto.type == 0 ? .file : .unsupported)
        let remoteWritable = dto.capability?.contains("w") ?? false
        let contentWritable = capabilitySnapshot.canWrite(provider: providerName) && remoteWritable
        let metadataWritable = capabilitySnapshot.stableItemIdentity == .verified && capabilitySnapshot.stableRootIdentity == .verified && capabilitySnapshot.conditionalMetadataMutation == .verified && capabilitySnapshot.operations.metadataMove == .verified && remoteWritable
        let writable = kind == .folder ? metadataWritable : (hasReliableContentRevision && (contentWritable || metadataWritable))
        let trashable = remoteWritable && capabilitySnapshot.canTrash
        let purgeable = remoteWritable && capabilitySnapshot.canPurge
        let readable = dto.permission.map { $0.contains("r") } ?? true
        let remoteDeletable = dto.capability?.contains("d") ?? false
        let contentType = kind == .folder ? UTType.folder.identifier : (kind == .symlink ? UTType.symbolicLink.identifier : UTType.data.identifier)
        return RemoteItem(itemIdentifier: itemIdentifier ?? CloudreveIdentifier.item(), remoteID: dto.id, parentIdentifier: parentIdentifier, name: dto.name, uri: normalizedURI, kind: kind, contentType: contentType, size: max(0, dto.size ?? 0), remoteVersion: dto.primaryEntity, version: ItemVersion(content: VersionHasher.content(primaryEntity: contentRevision), metadata: VersionHasher.metadata(parent: parentIdentifier, name: dto.name, kind: kind, permissionBits: readable ? 1 : 0, revision: dto.updatedAt)), creationDate: parseRemoteDate(dto.createdAt), contentModificationDate: parseRemoteDate(dto.updatedAt), canRead: readable && kind != .unsupported, canWrite: writable && readable && kind != .unsupported, canAddChildren: remoteWritable && readable && kind == .folder && capabilitySnapshot.stableItemIdentity == .verified && capabilitySnapshot.stableRootIdentity == .verified && capabilitySnapshot.operations.collisionSafeCreate == .verified, canTrash: trashable && readable && remoteDeletable, canDelete: purgeable && readable && remoteDeletable)
    }

    private func request<Value: Decodable>(path: String, method: String, query: [URLQueryItem], body: [String: Any]?, authenticated: Bool) throws -> Value {
        let makeRequest: (Credential?) throws -> URLRequest = { credentialOverride in
            try self.makeRequest(path: path, method: method, query: query, body: body, authenticated: authenticated, credentialOverride: credentialOverride)
        }
        var request = try makeRequest(nil)
        var result = try perform(request)
        guard let httpResponse = result.1 as? HTTPURLResponse else { throw CoreFailure(code: .network, retryable: true) }
        guard (200..<300).contains(httpResponse.statusCode) else {
            logger.error("api.failed path=\(path, privacy: .public) http_status=\(httpResponse.statusCode, privacy: .public)")
            throw mapHTTPStatus(httpResponse.statusCode)
        }

        var envelope = try JSONDecoder().decode(APIEnvelope<Value>.self, from: result.0)
        if authenticated, envelope.code != 0, isAuthenticationAPIError(code: envelope.code, message: envelope.msg) {
            logger.info("api.auth_retry path=\(path, privacy: .public) api_code=\(envelope.code, privacy: .public)")
            let refreshed = try refreshCredentialSynchronously()
            request = try makeRequest(refreshed)
            result = try performOnce(request)
            guard let retryResponse = result.1 as? HTTPURLResponse else { throw CoreFailure(code: .network, retryable: true) }
            guard (200..<300).contains(retryResponse.statusCode) else {
                logger.error("api.failed path=\(path, privacy: .public) http_status=\(retryResponse.statusCode, privacy: .public) after_auth_retry=true")
                throw mapHTTPStatus(retryResponse.statusCode)
            }
            envelope = try JSONDecoder().decode(APIEnvelope<Value>.self, from: result.0)
        }

        guard envelope.code == 0 else {
            logger.error("api.failed path=\(path, privacy: .public) api_code=\(envelope.code, privacy: .public)")
            throw mapAPIError(envelope.code, message: envelope.msg)
        }
        if let value = envelope.data { return value }
        if Value.self == EmptyResponse.self, let empty = EmptyResponse() as? Value { return empty }
        throw CoreFailure(code: .unknownOutcome, retryable: false)
    }

    private func makeRequest(path: String, method: String, query: [URLQueryItem], body: [String: Any]?, authenticated: Bool, credentialOverride: Credential?) throws -> URLRequest {
        var url = origin.appendingPathComponent("api/v4").appendingPathComponent(path)
        if !query.isEmpty { var components = URLComponents(url: url, resolvingAgainstBaseURL: false); components?.queryItems = query; url = components?.url ?? url }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let clientID, !clientID.isEmpty {
            request.setValue(clientID, forHTTPHeaderField: "X-Cr-Client-Id")
        }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if authenticated {
            let credential: Credential?
            if let credentialOverride {
                credential = credentialOverride
            } else {
                credential = try vault.read(reference: credentialReference)
            }
            guard let credential else { throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true) }
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func signedDownloadURL(uri: String, entity: String?) throws -> URL {
        var body: [String: Any] = ["uris": [uri]]
        if let entity, !entity.isEmpty {
            body["entity"] = entity
        }
        let response: FileURLDTO = try request(path: "file/url", method: "POST", query: [], body: body, authenticated: true)
        guard let rawURL = response.urls.first?.url else {
            throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "invalid-download-url"])
        }
        let url = try safeExternalURL(rawURL)
        logger.info("download.url_received has_entity=\(entity != nil, privacy: .public) host=\(url.host ?? "unknown", privacy: .public)")
        return url
    }

    private func perform(_ request: URLRequest) throws -> (Data, URLResponse) {
        let result = try performOnce(request)
        guard (result.1 as? HTTPURLResponse)?.statusCode == 401,
              request.value(forHTTPHeaderField: "Authorization") != nil else {
            return result
        }
        var retry = request
        let refreshed = try refreshCredentialSynchronously()
        retry.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
        return try performOnce(retry)
    }

    private func performOnce(_ request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        let result = URLSessionResult()
        let task = session.dataTask(with: request) { data, response, error in
            result.set(data: data ?? Data(), response: response, error: error)
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + requestTimeout) == .success else { task.cancel(); throw CoreFailure(code: .network, retryable: true) }
        if result.error != nil { throw CoreFailure(code: .network, retryable: true, redactedContext: ["error": "url_session"]) }
        guard let resultResponse = result.response else { throw CoreFailure(code: .network, retryable: true) }
        return (result.data, resultResponse)
    }

    private func refreshCredentialSynchronously() throws -> Credential {
        let semaphore = DispatchSemaphore(value: 0)
        let result = CredentialRefreshResult()
        let task = Task {
            do {
                let credential = try await credentialRefresh.credential(origin: origin, reference: credentialReference, forceRefresh: true)
                result.set(credential: credential)
            } catch {
                result.set(error: error)
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + requestTimeout) == .success else {
            task.cancel()
            throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true)
        }
        if result.error != nil {
            throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true)
        }
        guard let credential = result.credential else {
            throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true)
        }
        return credential
    }

    private func downloadWithoutBearer(url: URL, to destination: URL, expectedSize: Int64) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let result = URLSessionResult()
        let task = session.downloadTask(with: URLRequest(url: url, timeoutInterval: requestTimeout)) { url, response, error in
            result.set(data: Data(), response: response, error: error, temporaryURL: url)
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + requestTimeout) == .success else { task.cancel(); throw CoreFailure(code: .network, retryable: true) }
        if result.error != nil {
            logger.error("download.url_failed reason=url_session")
            throw CoreFailure(code: .network, retryable: true, redactedContext: ["error": "url_session"])
        }
        guard let response = result.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            try? FileManager.default.removeItem(at: destination)
            let status = (result.response as? HTTPURLResponse)?.statusCode ?? 0
            logger.error("download.url_failed reason=http_status status=\(status, privacy: .public)")
            throw DownloadHTTPError(statusCode: status)
        }
        guard let temporaryURL = result.temporaryURL else {
            logger.error("download.url_failed reason=missing_temporary_file")
            throw CoreFailure(code: .network, retryable: true)
        }
        let input = try FileHandle(forReadingFrom: temporaryURL)
        defer {
            try? input.close()
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        if !FileManager.default.fileExists(atPath: destination.path) {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                logger.error("download.url_failed reason=destination_unavailable")
                throw CoreFailure(code: .network, retryable: true)
            }
        }
        let output = try FileHandle(forWritingTo: destination)
        try output.truncate(atOffset: 0)
        defer { try? output.close() }
        var total: Int64 = 0
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
            total += Int64(chunk.count)
        }
        guard total == expectedSize else {
            try? FileManager.default.removeItem(at: destination)
            logger.error("download.url_failed reason=size_mismatch expected=\(expectedSize, privacy: .public) actual=\(total, privacy: .public)")
            throw CoreFailure(code: .integrityFailure, retryable: true)
        }
    }
}

extension NimbusSyncRemoteBackend: SnapshotAwareFileProviderBackend {
    public func childrenPage(parentIdentifier: String, offset: Int, limit: Int, snapshotID: String, generation: UInt64) throws -> DirectoryPage {
        try store.directorySnapshotPage(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier, generation: generation, snapshotID: snapshotID, offset: offset, limit: limit)
    }
}

private func parseRemoteDate(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    return ISO8601DateFormatter().date(from: value)
}

private func stableOperationID(_ value: String) -> UUID {
    if value.hasPrefix("cri-"), let uuid = UUID(uuidString: String(value.dropFirst(4))) { return uuid }
    let digest = SHA256.hash(data: Data(value.utf8))
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
}

private struct DownloadHTTPError: Error {
    let statusCode: Int
}

private final class URLSessionResult: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var data = Data()
    private(set) var response: URLResponse?
    private(set) var error: Error?
    private(set) var temporaryURL: URL?

    func set(data: Data, response: URLResponse?, error: Error?, temporaryURL: URL? = nil) {
        lock.lock()
        self.data = data; self.response = response; self.error = error; self.temporaryURL = temporaryURL
        lock.unlock()
    }
}

private final class CredentialRefreshResult: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var credential: Credential?
    private(set) var error: Error?

    func set(credential: Credential) {
        lock.lock()
        self.credential = credential
        lock.unlock()
    }

    func set(error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }
}

private func mapHTTPStatus(_ status: Int) -> CoreFailure {
    switch status {
    case 401: return CoreFailure(code: .authentication, retryable: false, userActionRequired: true)
    case 403: return CoreFailure(code: .permissionDenied, retryable: false)
    case 404: return CoreFailure(code: .notFound, retryable: false)
    case 409: return CoreFailure(code: .nameCollision, retryable: false, userActionRequired: true)
    case 412: return CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true)
    case 507: return CoreFailure(code: .quotaExceeded, retryable: false, userActionRequired: true)
    default: return CoreFailure(code: .network, retryable: true)
    }
}

private func isAuthenticationAPIError(code: Int, message: String?) -> Bool {
    switch code {
    case 401, 40020, 40089:
        return true
    case 40081:
        return message?.range(of: "login required", options: [.caseInsensitive, .diacriticInsensitive]) != nil
    default:
        return false
    }
}

private func mapAPIError(_ code: Int, message: String? = nil) -> CoreFailure {
    if isAuthenticationAPIError(code: code, message: message) {
        return CoreFailure(code: .authentication, retryable: false, userActionRequired: true)
    }
    switch code {
    case 40006, 40007, 40008:
        return CoreFailure(code: .permissionDenied, retryable: false)
    case 40009, 40010:
        return CoreFailure(code: .notFound, retryable: false)
    case 40081:
        return CoreFailure(code: .unknownOutcome, retryable: true)
    default:
        return CoreFailure(code: .unknownOutcome, retryable: false)
    }
}

private struct UploadPartDescriptor {
    let index: Int
    let offset: Int
    let length: Int
}

private func planParts(size: Int, chunkSize: Int) -> [UploadPartDescriptor] {
    let chunkSize = max(1, chunkSize)
    if size == 0 { return [UploadPartDescriptor(index: 0, offset: 0, length: 0)] }
    var result: [UploadPartDescriptor] = []
    var offset = 0
    var index = 0
    while offset < size {
        let length = min(chunkSize, size - offset)
        result.append(UploadPartDescriptor(index: index, offset: offset, length: length))
        offset += length; index += 1
    }
    return result
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

extension NimbusSyncRemoteBackend: CloudreveAsyncBackend {
    public func item(identifier: String) async throws -> RemoteItem? {
        try await Task.detached(priority: .userInitiated) { try self.item(identifier: identifier) }.value
    }

    public func childrenPage(parentIdentifier: String, cursor: PageCursor?) async throws -> RemotePage {
        let context = FileProviderOperationContext(
            itemIdentifier: NSFileProviderItemIdentifier(parentIdentifier),
            progress: Progress(totalUnitCount: 1),
            registrar: NoopURLSessionTaskRegistrar(),
            cancellation: CancellationToken()
        )
        return try await childrenPage(parentIdentifier: parentIdentifier, cursor: cursor, context: context)
    }

    public func childrenPage(parentIdentifier: String, cursor: PageCursor?, context: FileProviderOperationContext) async throws -> RemotePage {
        let offset = cursor?.opaqueCursor.flatMap { Int(String(data: $0, encoding: .utf8) ?? "") } ?? 0
        if let cursor, let snapshotID = cursor.snapshotID {
            // A Finder page may outlive publication of a newer head. The
            // token names the immutable snapshot, so it remains valid until
            // its own TTL rather than being rejected merely because it is no
            // longer current.
            do {
                let page = try store.directorySnapshotPage(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier, generation: cursor.generation, snapshotID: snapshotID, offset: offset, limit: 200)
                let next = page.nextOffset.map { PageCursor(generation: page.generation, opaqueCursor: Data(String($0).utf8), snapshotID: page.snapshotID, expiresAt: page.expiresAt.map { Int64($0.timeIntervalSince1970) }) }
                return RemotePage(items: page.items, nextCursor: next, complete: page.complete, snapshotID: page.snapshotID, expiresAt: page.expiresAt.map { Int64($0.timeIntervalSince1970) })
            } catch let error as StoreBridgeError where error == .pageTokenInvalid {
                // The snapshot is still collecting; resume hydration below.
            }
            guard let active = try store.activeDirectorySnapshot(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier), active.snapshotID == snapshotID, active.generation == cursor.generation else {
                throw StoreBridgeError.snapshotExpired
            }
        }
        if cursor == nil, let snapshot = try store.currentCompleteDirectorySnapshot(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier) {
            let page = try store.directorySnapshotPage(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier, generation: snapshot.generation, snapshotID: snapshot.snapshotID, offset: offset, limit: 200)
            let next = page.nextOffset.map { PageCursor(generation: page.generation, opaqueCursor: Data(String($0).utf8), snapshotID: page.snapshotID, expiresAt: page.expiresAt.map { Int64($0.timeIntervalSince1970) }) }
            return RemotePage(items: page.items, nextCursor: next, complete: page.complete, snapshotID: page.snapshotID, expiresAt: page.expiresAt.map { Int64($0.timeIntervalSince1970) })
        }
        let uri = try await parentURIAsync(for: parentIdentifier, context: context)
        let active: DirectorySnapshotDescriptor
        if let cursor, let snapshotID = cursor.snapshotID {
            guard let collecting = try store.activeDirectorySnapshot(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier), collecting.snapshotID == snapshotID else {
                throw StoreBridgeError.snapshotExpired
            }
            active = collecting
        } else {
            // Keep an interrupted hydration generation and resume it on the
            // next initial-page retry. Starting a fresh generation here would
            // discard the durable cursor and turn a retry into a drifting
            // live-offset scan.
            active = try store.activeDirectorySnapshot(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier)
                ?? store.beginDirectorySnapshot(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier)
        }
        let storedCursor = active.nextCursor.flatMap { String(data: $0, encoding: .utf8) }
        var query = [
            URLQueryItem(name: "uri", value: uri),
            URLQueryItem(name: "page_size", value: "200"),
            URLQueryItem(name: "order_by", value: "name"),
            URLQueryItem(name: "order_direction", value: "asc")
        ]
        if let storedCursor, storedCursor.hasPrefix("token:") {
            query.append(URLQueryItem(name: "next_page_token", value: String(storedCursor.dropFirst("token:".count))))
        } else {
            let page = storedCursor.flatMap { $0.hasPrefix("page:") ? Int($0.dropFirst("page:".count)) : nil } ?? 1
            query.append(URLQueryItem(name: "page", value: String(page)))
        }
        let response: RemoteListDTO = try await requestAsync(path: "file", method: "GET", query: query, body: nil, authenticated: true, context: context)
        var mapped: [RemoteItem] = []
        var pageIdentities: [String: String] = [:]
        for dto in response.files {
            let identifier: String
            if let existing = pageIdentities[dto.id] {
                identifier = existing
            } else {
                identifier = try store.itemIdentifier(forRemoteID: dto.id) ?? CloudreveIdentifier.item()
                pageIdentities[dto.id] = identifier
            }
            mapped.append(try makeItem(dto, parentIdentifier: parentIdentifier, itemIdentifier: identifier))
        }
        let nextCursor: Data?
        let requestUsedCursor = storedCursor?.hasPrefix("token:") == true
        if let token = response.pagination?.nextToken {
            guard paginationContinuationIsVerified(capabilitySnapshot, usesCursor: true) else {
                throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_capability"])
            }
            guard !token.isEmpty, token.utf8.count <= 64 * 1024 else {
                throw CoreFailure(code: .unknownOutcome, retryable: true, userActionRequired: true, redactedContext: ["stage": "directory_snapshot_cursor"])
            }
            nextCursor = Data("token:\(token)".utf8)
        } else if requestUsedCursor {
            nextCursor = nil
        } else if let total = response.pagination?.totalItems {
            let page = storedCursor.flatMap { $0.hasPrefix("page:") ? Int($0.dropFirst("page:".count)) : nil } ?? 1
            let effectivePageSize = max(1, response.pagination?.pageSize ?? 200)
            let currentPage = max(1, response.pagination?.page ?? page)
            if Int64(currentPage) * Int64(effectivePageSize) >= total {
                nextCursor = nil
            } else {
                guard paginationContinuationIsVerified(capabilitySnapshot, usesCursor: false) else {
                    throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_capability"])
                }
                nextCursor = Data("page:\(currentPage + 1)".utf8)
            }
        } else if mapped.count >= 200 {
            guard paginationContinuationIsVerified(capabilitySnapshot, usesCursor: false) else {
                throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_capability"])
            }
            let page = storedCursor.flatMap { $0.hasPrefix("page:") ? Int($0.dropFirst("page:".count)) : nil } ?? 1
            nextCursor = Data("page:\(page + 1)".utf8)
        } else {
            nextCursor = nil
        }
        if nextCursor == nil {
            guard paginationCompletionIsVerified(capabilitySnapshot) else {
                throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_completion_capability"])
            }
        }
        try store.appendDirectorySnapshotItems(snapshotID: active.snapshotID, items: mapped, nextCursor: nextCursor)
        if nextCursor == nil {
            try store.publishDirectorySnapshot(snapshotID: active.snapshotID)
            let stablePage = try store.directorySnapshotPage(
                domainIdentifier: domainIdentifier,
                parentIdentifier: parentIdentifier,
                generation: active.generation,
                snapshotID: active.snapshotID,
                offset: offset,
                limit: 200
            )
            let stableNext = stablePage.nextOffset.map {
                PageCursor(
                    generation: stablePage.generation,
                    opaqueCursor: Data(String($0).utf8),
                    snapshotID: stablePage.snapshotID,
                    expiresAt: stablePage.expiresAt.map { Int64($0.timeIntervalSince1970) }
                )
            }
            return RemotePage(
                items: stablePage.items,
                nextCursor: stableNext,
                complete: stablePage.complete,
                snapshotID: stablePage.snapshotID,
                expiresAt: stablePage.expiresAt.map { Int64($0.timeIntervalSince1970) }
            )
        }
        // Until the generation is complete, no page is exposed to Finder:
        // doing so would mix an in-flight remote listing with an immutable
        // local snapshot on the following request. The durable cursor above
        // lets a later initial-page retry continue hydration.
        throw CoreFailure(code: .cannotSynchronize, retryable: true, userActionRequired: true, redactedContext: ["stage": "directory_snapshot_hydrating"])
    }

    /// Hydrates the provider-synchronised trash view from the server contract.
    /// A verified capability is required by the caller and the result is
    /// bounded; an incomplete/unknown server response is an error, never an
    /// empty successful trash listing.
    public func trashItems() async throws -> [RemoteItem] {
        let context = FileProviderOperationContext(itemIdentifier: .trashContainer, progress: Progress(totalUnitCount: 1), registrar: NoopURLSessionTaskRegistrar(), cancellation: CancellationToken())
        return try await trashItems(context: context)
    }

    public func trashItems(context: FileProviderOperationContext) async throws -> [RemoteItem] {
        guard capabilitySnapshot.canTrash else {
            throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true)
        }
        let pageSize = 200
        var page = 1
        var token: String?
        var usedTokens = Set<String>()
        var result: [RemoteItem] = []
        var resultIndexes: [String: Int] = [:]
        let rootRemoteID = try store.domain(identifier: domainIdentifier)?.rootRemoteID
        while true {
            try context.cancellation.throwIfCancelled()
            guard page <= 2_000 else { throw CoreFailure(code: .quotaExceeded, retryable: false, userActionRequired: true, redactedContext: ["stage": "trash_listing_bound"]) }
            let query = [
                URLQueryItem(name: "uri", value: "cloudreve://trash"),
                URLQueryItem(name: "page_size", value: String(pageSize)),
                URLQueryItem(name: "order_by", value: "name"),
                URLQueryItem(name: "order_direction", value: "asc"),
            ] + (token.map { [URLQueryItem(name: "next_page_token", value: $0)] } ?? [URLQueryItem(name: "page", value: String(page))])
            let requestUsedCursor = token != nil
            let response: RemoteListDTO = try await requestAsync(path: "file", method: "GET", query: query, body: nil, authenticated: true, context: context)
            for dto in response.files {
                guard !dto.id.isEmpty, dto.id != rootRemoteID else { continue }
                let identifier = try store.itemIdentifier(forRemoteID: dto.id) ?? CloudreveIdentifier.item()
                let previous = try store.item(identifier: identifier)
                var item = try makeItem(dto, parentIdentifier: NSFileProviderItemIdentifier.trashContainer.rawValue, itemIdentifier: identifier)
                item.trashed = true
                item.trashOriginalParentIdentifier = previous?.trashOriginalParentIdentifier ?? (previous?.trashed == true ? nil : previous?.parentIdentifier)
                if let index = resultIndexes[identifier] {
                    result[index] = item
                } else {
                    resultIndexes[identifier] = result.count
                    result.append(item)
                }
                guard result.count <= 100_000 else { throw CoreFailure(code: .quotaExceeded, retryable: false, userActionRequired: true, redactedContext: ["stage": "trash_listing_bound"]) }
            }
            if let next = response.pagination?.nextToken {
                guard paginationContinuationIsVerified(capabilitySnapshot, usesCursor: true) else {
                    throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_capability"])
                }
                guard !next.isEmpty, usedTokens.insert(next).inserted else { throw CoreFailure(code: .unknownOutcome, retryable: true, userActionRequired: true) }
                token = next
                continue
            }
            if requestUsedCursor {
                guard paginationContinuationIsVerified(capabilitySnapshot, usesCursor: true) else {
                    throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_completion_capability"])
                }
                let sorted = result.sorted { ($0.name.localizedStandardCompare($1.name) == .orderedAscending) || ($0.name == $1.name && $0.itemIdentifier < $1.itemIdentifier) }
                try context.cancellation.throwIfCancelled()
                try store.insertItems(sorted)
                return sorted
            }
            if let total = response.pagination?.totalItems, Int64(result.count) < total {
                guard paginationContinuationIsVerified(capabilitySnapshot, usesCursor: false) else {
                    throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_capability"])
                }
                guard !response.files.isEmpty else {
                    throw CoreFailure(code: .unknownOutcome, retryable: true, userActionRequired: true, redactedContext: ["stage": "trash_listing_incomplete"])
                }
                page += 1
                token = nil
                continue
            }
            if response.pagination == nil && response.files.count >= pageSize {
                guard paginationContinuationIsVerified(capabilitySnapshot, usesCursor: false) else {
                    throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_capability"])
                }
                page += 1
                continue
            }
            guard paginationCompletionIsVerified(capabilitySnapshot) else {
                throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "pagination_completion_capability"])
            }
            let sorted = result.sorted { ($0.name.localizedStandardCompare($1.name) == .orderedAscending) || ($0.name == $1.name && $0.itemIdentifier < $1.itemIdentifier) }
            try context.cancellation.throwIfCancelled()
            try store.insertItems(sorted)
            return sorted
        }
    }

    public func fetchContent(identifier: String, expectedVersion: Data?, destination: URL, context: FileProviderOperationContext) async throws -> RemoteItem {
        try context.cancellation.throwIfCancelled()
        var stage = "lookup_item"
        do {
            guard let stored = try store.item(identifier: identifier), stored.remoteID != nil else { throw CoreFailure(code: .notFound, retryable: false) }
            guard stored.canRead else { throw CoreFailure(code: .permissionDenied, retryable: false, userActionRequired: true) }
            if let expectedVersion, expectedVersion != stored.version.content { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }
            let current = expectedVersion == nil ? try await fetchRemoteItemAsync(fallback: stored, context: context) : stored
            if current != stored {
                try commitFetchedMetadataChange(old: stored, new: current)
            }
            try context.cancellation.throwIfCancelled()
            stage = "request_download_url"
            let entity = current.remoteVersion?.isEmpty == false ? current.remoteVersion : nil
            var signedURL = try await signedDownloadURLAsync(uri: try canonicalRemoteURI(current.uri), entity: entity, context: context)
            stage = "download"
            do {
                try await downloadWithoutBearerAsync(url: signedURL, to: destination, expectedSize: current.size, context: context)
            } catch let error as DownloadHTTPError where error.statusCode == 404 && entity != nil {
                signedURL = try await signedDownloadURLAsync(uri: try canonicalRemoteURI(current.uri), entity: nil, context: context)
                try await downloadWithoutBearerAsync(url: signedURL, to: destination, expectedSize: current.size, context: context)
            }
            stage = "verify_remote_version"
            let refreshed = try await fetchRemoteItemAsync(fallback: current, context: context)
            if refreshed != current {
                try commitFetchedMetadataChange(old: current, new: refreshed)
            }
            if refreshed.version.content != current.version.content {
                try? FileManager.default.removeItem(at: destination)
                throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true)
            }
            return refreshed
        } catch let error as DownloadHTTPError {
            throw CoreFailure(code: .network, retryable: true, redactedContext: ["http-status": String(error.statusCode), "stage": stage])
        }
    }

    public func create(_ request: CreateRequest, context: FileProviderOperationContext) async throws -> RemoteItem {
        try requireOperation("create")
        if request.template.kind == .file, let contents = request.contents {
            try requireSyncableSource(contents)
            try requireOperation("content")
            if let size = try? FileManager.default.attributesOfItem(atPath: contents.path)[.size] as? NSNumber, size.int64Value == 0 {
                try requireOperation("zero_byte")
            }
        } else if request.template.kind == .file {
            try requireOperation("zero_byte")
        }
        try validateName(request.template.name)
        guard request.template.canWrite else { throw CoreFailure(code: .permissionDenied, retryable: false, userActionRequired: true) }
        let parent = request.template.parentIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue
        let parentURI = try await parentURIAsync(for: parent, context: context)
        let targetURI = try CloudreveRemoteURI.append(parentURI, name: request.template.name)
        if let contents = request.contents, request.template.kind != .folder {
            return try await uploadFileAsync(uri: targetURI, source: contents, previous: nil, itemIdentifier: request.template.itemIdentifier, parentIdentifier: parent, context: context)
        }
        let dto: RemoteFileDTO = try await requestAsync(path: "file/create", method: "POST", query: [], body: ["uri": targetURI, "type": request.template.kind == .folder ? "folder" : "file", "err_on_conflict": true], authenticated: true, context: context)
        return try makeItem(dto, parentIdentifier: parent, itemIdentifier: request.template.itemIdentifier)
    }

    public func modify(_ request: ModifyRequest, context: FileProviderOperationContext) async throws -> RemoteItem {
        if request.changedFields.contains(.contents) { try requireOperation("content") }
        if request.changedFields.contains(.filename) || request.changedFields.contains(.parentItemIdentifier) { try requireOperation("metadata_move") }
        guard let stored = try store.item(identifier: request.item.itemIdentifier) else { throw CoreFailure(code: .notFound, retryable: false) }
        if request.changedFields.contains(.lastUsedDate) && request.changedFields.subtracting([.lastUsedDate]).isEmpty {
            var state = try store.localItemState(identifier: stored.itemIdentifier)
            state.lastUsedAt = Date()
            try store.setLocalItemState(identifier: stored.itemIdentifier, state: state)
            return stored
        }
        guard stored.canWrite else { throw CoreFailure(code: .permissionDenied, retryable: false, userActionRequired: true) }
        if let expectedVersion = request.expectedVersion, expectedVersion != stored.version.content {
            throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true)
        }
        try context.cancellation.throwIfCancelled()
        var result = stored
        if request.changedFields.contains(.contents) {
            guard let source = request.contents else { throw CoreFailure(code: .awaitingSourceReplay, retryable: false, userActionRequired: true) }
            try requireSyncableSource(source)
            guard let previous = stored.remoteVersion, !previous.isEmpty else {
                throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "missing_previous_version"])
            }
            result = try await uploadFileAsync(uri: stored.uri, source: source, previous: previous, itemIdentifier: stored.itemIdentifier, parentIdentifier: stored.parentIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue, context: context)
        }
        if request.changedFields.contains(.filename) {
            try validateName(request.item.name)
            let dto: RemoteFileDTO = try await requestAsync(path: "file/rename", method: "POST", query: [], body: ["uri": result.uri, "new_name": request.item.name], authenticated: true, context: context)
            result = try makeItem(dto, parentIdentifier: result.parentIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue, itemIdentifier: result.itemIdentifier)
        }
        if request.changedFields.contains(.parentItemIdentifier) {
            guard capabilitySnapshot.conditionalMetadataMutation == .verified, capabilitySnapshot.operations.metadataMove == .verified else { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
            let destination = try await parentURIAsync(for: request.item.parentIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue, context: context)
            let _: EmptyResponse = try await requestAsync(path: "file/move", method: "POST", query: [], body: ["uris": [result.uri], "dst": destination, "copy": false], authenticated: true, context: context)
            result.parentIdentifier = request.item.parentIdentifier
            result.uri = try CloudreveRemoteURI.append(destination, name: result.name)
        }
        return result
    }

    public func trash(_ request: TrashRequest, context: FileProviderOperationContext) async throws -> RemoteItem {
        try requireOperation("trash")
        guard let current = try store.item(identifier: request.item.itemIdentifier) else { throw CoreFailure(code: .notFound, retryable: false) }
        guard current.canTrash else { throw CoreFailure(code: .permissionDenied, retryable: false, userActionRequired: true) }
        if let expectedVersion = request.expectedVersion, expectedVersion != current.version.content { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }
        let _: EmptyResponse = try await requestAsync(path: "file", method: "DELETE", query: [], body: ["uris": [current.uri], "skip_soft_delete": false], authenticated: true, context: context)
        var trashed = current
        trashed.trashed = true
        trashed.trashOriginalParentIdentifier = current.parentIdentifier
        trashed.parentIdentifier = NSFileProviderItemIdentifier.trashContainer.rawValue
        return trashed
    }

    public func restore(_ request: RestoreRequest, context: FileProviderOperationContext) async throws -> RemoteItem {
        try requireOperation("trash")
        guard let current = try store.item(identifier: request.item.itemIdentifier) else { throw CoreFailure(code: .notFound, retryable: false) }
        guard current.trashed else { throw CoreFailure(code: .cannotSynchronize, retryable: false, userActionRequired: true) }
        guard current.canTrash else { throw CoreFailure(code: .permissionDenied, retryable: false, userActionRequired: true) }
        if let expectedVersion = request.expectedVersion, expectedVersion != current.version.content { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }
        let _: EmptyResponse = try await requestAsync(path: "file/restore", method: "POST", query: [], body: ["uris": [current.uri]], authenticated: true, context: context)
        var restored = current
        restored.trashed = false
        restored.parentIdentifier = current.trashOriginalParentIdentifier ?? request.item.parentIdentifier
        restored.trashOriginalParentIdentifier = nil
        return restored
    }

    public func delete(_ request: DeleteRequest, context: FileProviderOperationContext) async throws {
        try requireOperation("purge")
        guard let current = try store.item(identifier: request.itemIdentifier) else { return }
        guard current.canDelete else { throw CoreFailure(code: .permissionDenied, retryable: false, userActionRequired: true) }
        if let expectedVersion = request.expectedVersion, expectedVersion != current.version.content { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }
        if current.kind == .folder && !request.recursive {
            let children = try store.listChildren(parentIdentifier: request.itemIdentifier)
            if !children.isEmpty { throw CoreFailure(code: .directoryNotEmpty, retryable: false) }
        }
        guard current.trashed, capabilitySnapshot.canPurge else { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
        do {
            let _: EmptyResponse = try await requestAsync(path: "file", method: "DELETE", query: [], body: ["uris": [current.uri], "skip_soft_delete": true], authenticated: true, context: context)
        } catch let failure as CoreFailure where failure.code == .notFound {
            // A purge is idempotent once the remote item is gone.
        }
    }

    private func requestAsync<Value: Decodable>(path: String, method: String, query: [URLQueryItem], body: [String: Any]?, authenticated: Bool, context: FileProviderOperationContext) async throws -> Value {
        try context.cancellation.throwIfCancelled()
        let transport = RegisteredURLSessionTransport(session: session)
        var request = try makeRequest(path: path, method: method, query: query, body: body, authenticated: authenticated, credentialOverride: nil)
        var result = try await transport.data(for: request, itemIdentifier: context.itemIdentifier, context: context)
        if authenticated, result.1.statusCode == 401 {
            let refreshed = try await credentialRefresh.credential(origin: origin, reference: credentialReference, forceRefresh: true)
            request = try makeRequest(path: path, method: method, query: query, body: body, authenticated: authenticated, credentialOverride: refreshed)
            result = try await transport.data(for: request, itemIdentifier: context.itemIdentifier, context: context)
        }
        guard (200..<300).contains(result.1.statusCode) else { throw mapHTTPStatus(result.1.statusCode) }
        var envelope = try JSONDecoder().decode(APIEnvelope<Value>.self, from: result.0)
        if authenticated, isAuthenticationAPIError(code: envelope.code, message: envelope.msg) {
            let refreshed = try await credentialRefresh.credential(origin: origin, reference: credentialReference, forceRefresh: true)
            request = try makeRequest(path: path, method: method, query: query, body: body, authenticated: authenticated, credentialOverride: refreshed)
            result = try await transport.data(for: request, itemIdentifier: context.itemIdentifier, context: context)
            guard (200..<300).contains(result.1.statusCode) else { throw mapHTTPStatus(result.1.statusCode) }
            envelope = try JSONDecoder().decode(APIEnvelope<Value>.self, from: result.0)
        }
        guard envelope.code == 0 else { throw mapAPIError(envelope.code, message: envelope.msg) }
        if let value = envelope.data { return value }
        if Value.self == EmptyResponse.self, let empty = EmptyResponse() as? Value { return empty }
        throw CoreFailure(code: .unknownOutcome, retryable: false)
    }

    private func requestBytesAsync(path: String, method: String, query: [URLQueryItem], body: Data?, authenticated: Bool, context: FileProviderOperationContext) async throws -> (Data, HTTPURLResponse) {
        try context.cancellation.throwIfCancelled()
        var request = try makeRequest(path: path, method: method, query: query, body: nil, authenticated: authenticated, credentialOverride: nil)
        request.httpBody = body
        if body != nil {
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(String(body?.count ?? 0), forHTTPHeaderField: "Content-Length")
        }
        let transport = RegisteredURLSessionTransport(session: session)
        var result = try await transport.data(for: request, itemIdentifier: context.itemIdentifier, context: context)
        if authenticated, result.1.statusCode == 401 {
            let refreshed = try await credentialRefresh.credential(origin: origin, reference: credentialReference, forceRefresh: true)
            request = try makeRequest(path: path, method: method, query: query, body: nil, authenticated: true, credentialOverride: refreshed)
            request.httpBody = body
            if body != nil {
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                request.setValue(String(body?.count ?? 0), forHTTPHeaderField: "Content-Length")
            }
            result = try await transport.data(for: request, itemIdentifier: context.itemIdentifier, context: context)
        }
        guard (200..<300).contains(result.1.statusCode) else { throw mapHTTPStatus(result.1.statusCode) }
        var envelope: APIEnvelope<EmptyResponse>? = try? JSONDecoder().decode(APIEnvelope<EmptyResponse>.self, from: result.0)
        if authenticated, let firstEnvelope = envelope, isAuthenticationAPIError(code: firstEnvelope.code, message: firstEnvelope.msg) {
            let refreshed = try await credentialRefresh.credential(origin: origin, reference: credentialReference, forceRefresh: true)
            request = try makeRequest(path: path, method: method, query: query, body: nil, authenticated: true, credentialOverride: refreshed)
            request.httpBody = body
            if body != nil {
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                request.setValue(String(body?.count ?? 0), forHTTPHeaderField: "Content-Length")
            }
            result = try await transport.data(for: request, itemIdentifier: context.itemIdentifier, context: context)
            guard (200..<300).contains(result.1.statusCode) else { throw mapHTTPStatus(result.1.statusCode) }
            envelope = try? JSONDecoder().decode(APIEnvelope<EmptyResponse>.self, from: result.0)
        }
        if let envelope, envelope.code != 0 {
            throw mapAPIError(envelope.code, message: envelope.msg)
        }
        return result
    }

    private func externalDataAsync(_ request: URLRequest, context: FileProviderOperationContext) async throws -> (Data, HTTPURLResponse) {
        try context.cancellation.throwIfCancelled()
        return try await RegisteredURLSessionTransport(session: session).data(
            for: request,
            itemIdentifier: context.itemIdentifier,
            context: context
        )
    }

    private func writeUpyunMultipartFile(source: URL, policy: String, authorization: String, mimeType: String?) throws -> (url: URL, boundary: String, length: Int64) {
        guard isSafeTransferValue(policy), isSafeTransferValue(authorization) else {
            throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true)
        }
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard let sourceSize = (sourceAttributes[.size] as? NSNumber)?.int64Value, sourceSize >= 0 else {
            throw CoreFailure(code: .integrityFailure, retryable: true, userActionRequired: true)
        }
        let boundary = "NimbusSync-\(UUID().uuidString)"
        let mime = (mimeType.flatMap { isSafeTransferValue($0, maximumLength: 256) ? $0 : nil }) ?? "application/octet-stream"
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"policy\"\r\n\r\n\(policy)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"authorization\"\r\n\r\n\(authorization)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"file\"\r\nContent-Type: \(mime)\r\n\r\n"
        let contentTypeField = mimeType.map { _ in "--\(boundary)\r\nContent-Disposition: form-data; name=\"content-type\"\r\n\r\n\(mime)\r\n" } ?? ""
        let footer = "\r\n\(contentTypeField)--\(boundary)--\r\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-upyun-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CoreFailure(code: .network, retryable: true)
        }
        do {
            let output = try FileHandle(forWritingTo: url)
            let input = try FileHandle(forReadingFrom: source)
            defer {
                try? input.close()
                try? output.close()
            }
            try output.write(contentsOf: Data(header.utf8))
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data(footer.utf8))
            return (url, boundary, Int64(header.utf8.count) + sourceSize + Int64(footer.utf8.count))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func uploadQiniuPartAsync(baseURL: URL, credential: String, index: Int, data: Data, context: FileProviderOperationContext) async throws -> String {
        guard isSafeTransferValue(credential) else {
            throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true)
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(String(index + 1)), timeoutInterval: requestTimeout)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        request.setValue("UpToken \(credential)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        let (body, response) = try await externalDataAsync(request, context: context)
        guard (200..<300).contains(response.statusCode),
              let decoded = try? JSONDecoder().decode(QiniuChunkResponse.self, from: body),
              let etag = decoded.etag,
              isSafeTransferValue(etag, maximumLength: 1024) else {
            throw CoreFailure(code: .unknownOutcome, retryable: true, userActionRequired: true, redactedContext: ["stage": "qiniu_part_response"])
        }
        return etag
    }

    private func uploadRemotePartAsync(url: URL, credential: String, index: Int, source: URL, length: Int64, context: FileProviderOperationContext) async throws {
        guard isSafeTransferValue(credential) else {
            throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query = components?.queryItems ?? []
        query.append(URLQueryItem(name: "chunk", value: String(index)))
        components?.queryItems = query
        guard let target = components?.url else {
            throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true)
        }
        var request = URLRequest(url: target, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(length), forHTTPHeaderField: "Content-Length")
        request.setValue(credential, forHTTPHeaderField: "Authorization")
        let response = try await RegisteredURLSessionTransport(session: session).uploadFile(
            from: source,
            request: request,
            itemIdentifier: context.itemIdentifier,
            context: context
        )
        guard (200..<300).contains(response.statusCode) else {
            throw mapHTTPStatus(response.statusCode)
        }
    }

    private func uploadUpyunPartAsync(url: URL, source: URL, policy: String, authorization: String, mimeType: String?, context: FileProviderOperationContext) async throws {
        let multipart = try writeUpyunMultipartFile(source: source, policy: policy, authorization: authorization, mimeType: mimeType)
        defer { try? FileManager.default.removeItem(at: multipart.url) }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(multipart.length), forHTTPHeaderField: "Content-Length")
        let response = try await RegisteredURLSessionTransport(session: session).uploadFile(
            from: multipart.url,
            request: request,
            itemIdentifier: context.itemIdentifier,
            context: context
        )
        guard (200..<300).contains(response.statusCode) else {
            throw mapHTTPStatus(response.statusCode)
        }
    }

    private func completeQiniuUploadAsync(baseURL: URL, credential: String, parts: [UploadPartCheckpoint], mimeType: String?, context: FileProviderOperationContext) async throws {
        guard isSafeTransferValue(credential) else {
            throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true)
        }
        let completedParts = parts.sorted { $0.index < $1.index }.compactMap { part -> [String: Any]? in
            guard let etag = part.etag, isSafeTransferValue(etag, maximumLength: 1024) else { return nil }
            return ["etag": etag, "partNumber": part.index + 1]
        }
        guard completedParts.count == parts.count else {
            throw CoreFailure(code: .unknownOutcome, retryable: true, userActionRequired: true, redactedContext: ["stage": "qiniu_missing_etag"])
        }
        var payload: [String: Any] = ["parts": completedParts]
        if let mimeType, isSafeTransferValue(mimeType, maximumLength: 256) {
            payload["mimeType"] = mimeType
        }
        var request = URLRequest(url: baseURL, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("UpToken \(credential)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await externalDataAsync(request, context: context)
        guard (200..<300).contains(response.statusCode) else {
            throw mapHTTPStatus(response.statusCode)
        }
    }

    private func uploadFileAsync(uri: String, source: URL, previous: String?, itemIdentifier: String, parentIdentifier: String, context: FileProviderOperationContext) async throws -> RemoteItem {
        let sourceFingerprint = try FileProviderSourceFingerprint.digest(url: source)
        if sourceFingerprint.size == 0 { try requireOperation("zero_byte") }
        let fingerprint = VersionHasher.digest([sourceFingerprint.hash, Data(String(sourceFingerprint.size).utf8), Data((previous ?? "").utf8)])
        let operationID = stableOperationID("\(itemIdentifier)|\(previous ?? "create")|\(fingerprint.base64EncodedString())")
        var activeSession: UploadSessionCheckpoint?
        var cache: UploadCredentialCache?
        if let existing = try store.uploadSession(operationID: operationID),
           existing.fingerprint == fingerprint,
           (existing.state == "completed" || existing.state == "verifying") {
            let result = try await fetchRemoteByURIAsync(uri: uri, fallbackIdentifier: itemIdentifier, parentIdentifier: parentIdentifier, context: context)
            var verified = existing
            verified.state = "completed"
            try store.saveUploadSession(verified)
            if let reference = verified.secretReference { discardTransferSecret(operationID: operationID, reference: reference) }
            return result
        }
        do {
            if let existing = try store.uploadSession(operationID: operationID),
               existing.state != "abandoned",
               existing.fingerprint == fingerprint,
               existing.expiresAt.map({ $0 > Date() }) ?? true,
               let reference = existing.secretReference,
               let encoded = try secretVault.readSecret(reference: reference),
               let data = Data(base64Encoded: encoded) {
                cache = try? JSONDecoder().decode(UploadCredentialCache.self, from: data)
                if cache != nil {
                    activeSession = existing
                } else {
                    var abandoned = existing
                    abandoned.state = "abandoned"
                    try store.saveUploadSession(abandoned)
                    if let reference = existing.secretReference { discardTransferSecret(operationID: operationID, reference: reference) }
                }
            } else if let existing = try store.uploadSession(operationID: operationID) {
                var abandoned = existing
                abandoned.state = "abandoned"
                try store.saveUploadSession(abandoned)
                if let reference = existing.secretReference { discardTransferSecret(operationID: operationID, reference: reference) }
            }

            if cache == nil {
                var body: [String: Any] = ["uri": uri, "size": sourceFingerprint.size, "policy_id": ""]
                if let previous {
                    body["previous"] = previous
                    body["entity_type"] = "version"
                }
                let credential: UploadCredentialDTO = try await requestAsync(path: "file/upload", method: "PUT", query: [], body: body, authenticated: true, context: context)
                guard isOpaqueTransferComponent(credential.sessionID) else {
                    throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "session_id"])
                }
                let provider = credential.storagePolicy?.type?.lowercased() ?? providerName.lowercased()
                guard provider.caseInsensitiveCompare(providerName) == .orderedSame else {
                    throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true)
                }
                let uploadURLs = try boundedUploadURLs(credential.uploadURLs ?? [], allowRelative: provider == "remote")
                let expiresAt = credential.expires > 0 ? Date(timeIntervalSince1970: TimeInterval(credential.expires)) : nil
                let reference = "transfer-\(operationID.uuidString)"
                let newCache = UploadCredentialCache(sessionID: credential.sessionID, credential: credential.credential, uploadPolicy: credential.uploadPolicy, mimeType: credential.mimeType, uploadURLs: uploadURLs, callbackSecret: credential.callbackSecret, completeURL: credential.completeURL, provider: provider, expiresAt: expiresAt)
                try secretVault.writeSecret(JSONEncoder().encode(newCache).base64EncodedString(), reference: reference)
                guard credential.chunkSize > 0, provider == "upyun" || credential.chunkSize <= 8 * 1024 * 1024 else {
                    throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "chunk_size"])
                }
                let chunkSize = Int(credential.chunkSize)
                guard sourceFingerprint.size <= Int64(Int.max) else { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
                let descriptors = provider == "upyun"
                    ? [UploadPartDescriptor(index: 0, offset: 0, length: Int(sourceFingerprint.size))]
                    : planParts(size: Int(sourceFingerprint.size), chunkSize: chunkSize)
                let parts = try descriptors.map { descriptor in
                    let sourceHash: Data
                    if provider == "upyun" {
                        sourceHash = sourceFingerprint.hash
                    } else {
                        let data = try readSourceChunk(source, offset: descriptor.offset, length: descriptor.length)
                        sourceHash = Data(SHA256.hash(data: data))
                    }
                    return UploadPartCheckpoint(index: descriptor.index, offset: Int64(descriptor.offset), length: Int64(descriptor.length), sourceHash: sourceHash)
                }
                let checkpointChunkSize = provider == "upyun" ? max(1, sourceFingerprint.size) : credential.chunkSize
                activeSession = UploadSessionCheckpoint(operationID: operationID, remoteSessionReference: credential.sessionID, secretReference: reference, fingerprint: fingerprint, provider: provider, chunkSize: checkpointChunkSize, expiresAt: expiresAt, state: "active", parts: parts)
                cache = newCache
                try store.saveUploadSession(activeSession!)
            }

            guard var session = activeSession, let cache else {
                throw CoreFailure(code: .awaitingSourceReplay, retryable: false, userActionRequired: true)
            }
            guard isOpaqueTransferComponent(cache.sessionID) else {
                throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "session_id"])
            }
            guard session.fingerprint == fingerprint else {
                throw CoreFailure(code: .awaitingSourceReplay, retryable: false, userActionRequired: true)
            }
            context.progress.totalUnitCount = max(1, sourceFingerprint.size)
            for index in session.parts.indices {
                try context.cancellation.throwIfCancelled()
                let part = session.parts[index]
                let provider = cache.provider.lowercased()
                let hash = provider == "upyun"
                    ? sourceFingerprint.hash
                    : Data(SHA256.hash(data: try readSourceChunk(source, offset: Int(part.offset), length: Int(part.length))))
                guard part.sourceHash.isEmpty || part.sourceHash == hash else {
                    throw CoreFailure(code: .awaitingSourceReplay, retryable: false, userActionRequired: true)
                }
                if part.state == "completed" {
                    context.progress.completedUnitCount = min(sourceFingerprint.size, context.progress.completedUnitCount + part.length)
                    continue
                }
                let etag: String?
                if provider == "qiniu" {
                    guard let uploadURL = cache.uploadURLs.first, !uploadURL.isEmpty,
                          let credential = cache.credential else {
                        throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "qiniu_credentials"])
                    }
                    let data = try readSourceChunk(source, offset: Int(part.offset), length: Int(part.length))
                    etag = try await uploadQiniuPartAsync(baseURL: try safeExternalURL(uploadURL), credential: credential, index: part.index, data: data, context: context)
                } else if provider == "upyun" {
                    guard part.index == 0,
                          let uploadURL = cache.uploadURLs.first, !uploadURL.isEmpty,
                          let policy = cache.uploadPolicy,
                          let credential = cache.credential else {
                        throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "upyun_credentials"])
                    }
                    try await uploadUpyunPartAsync(url: try safeExternalURL(uploadURL), source: source, policy: policy, authorization: credential, mimeType: cache.mimeType, context: context)
                    etag = nil
                } else if provider == "remote", let uploadURL = cache.uploadURLs.first, !uploadURL.isEmpty, !uploadURL.hasPrefix("/") {
                    guard let credential = cache.credential else {
                        throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "remote_credentials"])
                    }
                    let data = try readSourceChunk(source, offset: Int(part.offset), length: Int(part.length))
                    let partURL = try writeTemporaryPart(data)
                    defer { try? FileManager.default.removeItem(at: partURL) }
                    try await uploadRemotePartAsync(url: try safeExternalURL(uploadURL), credential: credential, index: part.index, source: partURL, length: part.length, context: context)
                    etag = nil
                } else {
                    let uploadIndex = provider == "onedrive" ? 0 : part.index
                    if ["s3", "oss", "cos", "ks3", "obs", "onedrive"].contains(provider) {
                        guard let uploadURL = cache.uploadURLs[safe: uploadIndex], !uploadURL.isEmpty else {
                            throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "missing-upload-url"])
                        }
                        let data = try readSourceChunk(source, offset: Int(part.offset), length: Int(part.length))
                        let partURL = try writeTemporaryPart(data)
                        defer { try? FileManager.default.removeItem(at: partURL) }
                        var request = URLRequest(url: try safeExternalURL(uploadURL), timeoutInterval: requestTimeout)
                        request.httpMethod = "PUT"
                        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
                        if provider == "onedrive", part.length > 0 {
                            request.setValue("bytes \(part.offset)-\(part.offset + part.length - 1)/\(sourceFingerprint.size)", forHTTPHeaderField: "Content-Range")
                        }
                        let response = try await RegisteredURLSessionTransport(session: self.session).uploadFile(from: partURL, request: request, itemIdentifier: context.itemIdentifier, context: context)
                        guard (200..<300).contains(response.statusCode) else { throw mapHTTPStatus(response.statusCode) }
                        etag = response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    } else {
                        let data = try readSourceChunk(source, offset: Int(part.offset), length: Int(part.length))
                        let response = try await requestBytesAsync(path: "file/upload/\(cache.sessionID)/\(part.index)", method: "POST", query: [], body: data, authenticated: true, context: context)
                        guard (200..<300).contains(response.1.statusCode) else { throw mapHTTPStatus(response.1.statusCode) }
                        etag = nil
                    }
                }
                session.parts[index].etag = etag
                session.parts[index].sourceHash = hash
                session.parts[index].state = "completed"
                session.parts[index].attempt += 1
                try store.saveUploadSession(session)
                context.progress.completedUnitCount = min(sourceFingerprint.size, context.progress.completedUnitCount + part.length)
            }
            let provider = cache.provider.lowercased()
            if provider == "qiniu" {
                guard let uploadURL = cache.uploadURLs.first, !uploadURL.isEmpty,
                      let credential = cache.credential else {
                    throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true, redactedContext: ["stage": "qiniu_credentials"])
                }
                try await completeQiniuUploadAsync(baseURL: try safeExternalURL(uploadURL), credential: credential, parts: session.parts, mimeType: cache.mimeType, context: context)
            } else if let completeURL = cache.completeURL, !completeURL.isEmpty, ["oss", "cos", "s3", "ks3", "obs"].contains(provider) {
                try await completeExternalUploadAsync(urlString: completeURL, provider: cache.provider, parts: session.parts, context: context)
            }
            let policy = provider.isEmpty ? providerName.lowercased() : provider
            if ["s3", "cos", "ks3", "onedrive"].contains(policy) {
                guard let secret = cache.callbackSecret, isOpaqueTransferComponent(secret, maximumLength: 512) else {
                    throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true)
                }
                _ = try await requestBytesAsync(path: "callback/\(policy)/\(cache.sessionID)/\(secret)", method: policy == "onedrive" ? "POST" : "GET", query: [], body: nil, authenticated: false, context: context)
            } else if policy != "local" && policy != "remote" && policy != "qiniu" && policy != "upyun" {
                throw CoreFailure(code: .unknownOutcome, retryable: false, userActionRequired: true)
            }
            session.state = "verifying"
            try store.saveUploadSession(session)
            let result = try await fetchRemoteByURIAsync(uri: uri, fallbackIdentifier: itemIdentifier, parentIdentifier: parentIdentifier, context: context)
            session.state = "completed"
            try store.saveUploadSession(session)
            if let reference = session.secretReference { discardTransferSecret(operationID: operationID, reference: reference) }
            return result
        } catch {
            if var session = activeSession, context.cancellation.isCancelled || (error as? CoreFailure)?.code == .cancelled {
                session.state = "awaiting_source_replay"
                try? store.saveUploadSession(session)
                try? store.setPending(itemIdentifier, templateIdentifier: nil, uploadError: "awaiting_source_replay")
                throw CoreFailure(code: .awaitingSourceReplay, retryable: false, userActionRequired: true)
            }
            throw error
        }
    }

    private func fetchRemoteItemAsync(fallback: RemoteItem, context: FileProviderOperationContext) async throws -> RemoteItem {
        let dto: RemoteFileDTO = try await requestAsync(path: "file/info", method: "GET", query: [
            URLQueryItem(name: "uri", value: try canonicalRemoteURI(fallback.uri)),
            URLQueryItem(name: "extended", value: "true")
        ], body: nil, authenticated: true, context: context)
        let normalized = try canonicalRemoteURI(dto.path)
        let parent = try await parentIdentifierForRemoteURIAsync(normalized, fallback: fallback.parentIdentifier, context: context)
        return try makeItem(dto, parentIdentifier: parent, itemIdentifier: fallback.itemIdentifier)
    }

    private func fetchRemoteByURIAsync(uri: String, fallbackIdentifier: String, parentIdentifier: String, context: FileProviderOperationContext) async throws -> RemoteItem {
        let dto: RemoteFileDTO = try await requestAsync(path: "file/info", method: "GET", query: [
            URLQueryItem(name: "uri", value: uri),
            URLQueryItem(name: "extended", value: "true")
        ], body: nil, authenticated: true, context: context)
        return try makeItem(dto, parentIdentifier: parentIdentifier, itemIdentifier: fallbackIdentifier)
    }

    private func signedDownloadURLAsync(uri: String, entity: String?, context: FileProviderOperationContext) async throws -> URL {
        var body: [String: Any] = ["uris": [uri]]
        if let entity, !entity.isEmpty { body["entity"] = entity }
        let response: FileURLDTO = try await requestAsync(path: "file/url", method: "POST", query: [], body: body, authenticated: true, context: context)
        guard let rawURL = response.urls.first?.url else {
            throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true)
        }
        let url = try safeExternalURL(rawURL)
        return url
    }

    private func downloadWithoutBearerAsync(url: URL, to destination: URL, expectedSize: Int64, context: FileProviderOperationContext) async throws {
        let request = URLRequest(url: url, timeoutInterval: requestTimeout)
        let response = try await RegisteredURLSessionTransport(session: session).download(to: destination, request: request, itemIdentifier: context.itemIdentifier, context: context)
        guard (200..<300).contains(response.statusCode) else {
            try? FileManager.default.removeItem(at: destination)
            throw DownloadHTTPError(statusCode: response.statusCode)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actualSize == expectedSize else {
            try? FileManager.default.removeItem(at: destination)
            throw CoreFailure(code: .integrityFailure, retryable: true, redactedContext: ["expected-size": String(expectedSize), "actual-size": String(actualSize)])
        }
    }

    private func readSourceChunk(_ source: URL, offset: Int, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, offset)))
        guard length > 0 else { return Data() }
        var result = Data()
        result.reserveCapacity(length)
        while result.count < length {
            guard let chunk = try handle.read(upToCount: length - result.count), !chunk.isEmpty else { break }
            result.append(chunk)
        }
        guard result.count == length else { throw CoreFailure(code: .awaitingSourceReplay, retryable: false, userActionRequired: true) }
        return result
    }

    private func requireSyncableSource(_ source: URL) throws {
        switch try SpecialFilePolicy.decision(for: source) {
        case .syncable:
            return
        case .excluded:
            throw CoreFailure(code: .excludedFromSync, retryable: false, userActionRequired: true)
        case .unsupportedMetadata:
            throw CoreFailure(code: .unsupportedMetadata, retryable: false, userActionRequired: true)
        }
    }

    private func writeTemporaryPart(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-part-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CoreFailure(code: .network, retryable: true) }
        try data.write(to: url, options: .atomic)
        return url
    }

    private func completeExternalUploadAsync(urlString: String, provider: String, parts: [UploadPartCheckpoint], context: FileProviderOperationContext) async throws {
        let url = try safeExternalURL(urlString)
        let xml = "<CompleteMultipartUpload>" + parts.sorted { $0.index < $1.index }.compactMap { part in
            guard let etag = part.etag else { return nil }
            let escaped = etag.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
            return "<Part><PartNumber>\(part.index + 1)</PartNumber><ETag>\(escaped)</ETag></Part>"
        }.joined() + "</CompleteMultipartUpload>"
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        switch provider.lowercased() {
        case "oss":
            request.setValue("true", forHTTPHeaderField: "x-oss-forbid-overwrite")
            request.setValue("yes", forHTTPHeaderField: "x-oss-complete-all")
            request.setValue("0", forHTTPHeaderField: "Content-Length")
            request.httpBody = Data()
        case "cos":
            request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            request.setValue("true", forHTTPHeaderField: "x-cos-forbid-overwrite")
            request.httpBody = Data(xml.utf8)
        case "s3", "ks3", "obs":
            request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(xml.utf8)
        default:
            throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true)
        }
        let response = try await RegisteredURLSessionTransport(session: session).data(for: request, itemIdentifier: context.itemIdentifier, context: context).1
        guard (200..<300).contains(response.statusCode) else { throw mapHTTPStatus(response.statusCode) }
    }
}
