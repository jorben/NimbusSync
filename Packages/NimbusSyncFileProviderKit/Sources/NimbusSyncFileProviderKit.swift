import Foundation
import FileProvider
import UniformTypeIdentifiers
import ImageIO
import AppKit
import OSLog
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveAuthKit
import CloudreveEventCoordinator
import CloudreveObservability

public final class NimbusSyncFileProviderItem: NSObject, NSFileProviderItem, NSFileProviderItemDecorating {
    public let model: RemoteItem
    public let itemIdentifier: NSFileProviderItemIdentifier
    public let parentItemIdentifier: NSFileProviderItemIdentifier
    public let filename: String
    public let contentType: UTType
    public let documentSize: NSNumber?
    public let childItemCount: NSNumber?
    public let creationDate: Date?
    public let contentModificationDate: Date?
    public let capabilities: NSFileProviderItemCapabilities
    public let fileSystemFlags: NSFileProviderFileSystemFlags
    public let contentPolicy: NSFileProviderContentPolicy
    public let itemVersion: NSFileProviderItemVersion
    public let userInfo: [AnyHashable: Any]?
    public let isUploaded: Bool
    public let isUploading: Bool
    public let uploadingError: Error?
    public let isDownloaded: Bool
    public let isDownloading: Bool
    public let downloadingError: Error?
    public let isMostRecentVersionDownloaded: Bool
    public let isShared: Bool
    public let isSharedByCurrentUser: Bool
    public let decorations: [NSFileProviderItemDecorationIdentifier]?

    public init(model: RemoteItem, isDownloaded: Bool = false, hasConflict: Bool = false, projection: ItemProjection? = nil, authenticated: Bool? = nil) {
        self.model = model
        self.itemIdentifier = NSFileProviderItemIdentifier(model.itemIdentifier == NSFileProviderItemIdentifier.rootContainer.rawValue ? model.itemIdentifier : model.itemIdentifier)
        self.parentItemIdentifier = NSFileProviderItemIdentifier(model.parentIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue)
		self.filename = model.name.isEmpty ? "NimbusSync" : model.name
        self.contentType = UTType(model.contentType) ?? (model.kind == .folder ? .folder : .data)
        self.documentSize = model.kind == .folder ? nil : NSNumber(value: model.size)
        let projectedDownloaded = projection?.localState.materialized ?? isDownloaded
        let projectedConflict = projection?.hasConflict ?? hasConflict
        let projectedAuthenticated = authenticated ?? model.canRead
        let explicitKeepPolicy = projection?.localState.keepPolicy ?? .inherit
        let effectiveKeepPolicy = projection?.effectiveKeepPolicy ?? (explicitKeepPolicy == .inherit ? .automatic : explicitKeepPolicy)
        let metadataMoveAllowed = projection?.metadataMoveAllowed ?? model.canWrite
        let isRoot = model.itemIdentifier == NSFileProviderItemIdentifier.rootContainer.rawValue
        self.childItemCount = projection?.childItemCount.map(NSNumber.init(value:))
        self.creationDate = model.creationDate
        self.contentModificationDate = model.contentModificationDate
        var itemCapabilities: NSFileProviderItemCapabilities = []
        if model.canRead { itemCapabilities.insert(.allowsReading) }
        if model.canWrite { itemCapabilities.insert(.allowsWriting) }
        if model.canAddChildren { itemCapabilities.insert(.allowsAddingSubItems) }
        if !isRoot {
            if metadataMoveAllowed { itemCapabilities.insert(.allowsRenaming); itemCapabilities.insert(.allowsReparenting) }
            if model.trashed {
                if model.canDelete { itemCapabilities.insert(.allowsDeleting) }
            } else if model.canTrash {
                // `rm` and application temp-file cleanup arrive as deletes, not
                // trash moves. Without .allowsDeleting the system rejects them
                // with EPERM; the backend maps such deletes to the Cloudreve
                // trash so they remain recoverable.
                itemCapabilities.insert(.allowsTrashing)
                itemCapabilities.insert(.allowsDeleting)
            }
        }
        self.capabilities = itemCapabilities
        if model.canRead && !model.tombstone {
            switch explicitKeepPolicy {
            case .keepDownloaded: self.contentPolicy = .downloadEagerlyAndKeepDownloaded
            case .inherit: self.contentPolicy = isRoot ? .downloadLazily : .inherited
            case .automatic: self.contentPolicy = .downloadLazily
            }
        } else {
            self.contentPolicy = .inherited
        }
        let operationState = projection?.operationState
        let uploadState = projection?.localState.uploadState ?? .none
        let downloadState = projection?.localState.downloadState ?? .none
        let uploadPending = ["queued", "running", "awaiting_source_replay"].contains(operationState ?? "") || uploadState == .queued || uploadState == .running || uploadState == .awaitingSourceReplay
        let downloadPending = downloadState == .queued || downloadState == .running
        let projectedUploaded = projection?.isUploaded ?? (model.remoteID != nil && !model.tombstone)
        let canManageDownloadPolicy = !isRoot && model.canRead && !model.tombstone && !projectedConflict && !uploadPending && projectedUploaded
        let canEvict = projectedDownloaded && effectiveKeepPolicy != .keepDownloaded && !uploadPending && !downloadPending && !projectedConflict && projectedUploaded
        // The metadata version describes remote metadata plus durable,
        // user-visible policy only. Transient local transfer state
        // (downloaded/uploading/child counts) is still projected on the item
        // and applied by the system without a version bump; folding it in
        // turned every completed download into a journaled metadata change.
        let projectionBoundary = VersionHasher.digest([
            Data(String(ProjectionSchema.currentRevision).utf8),
            Data(explicitKeepPolicy.rawValue.utf8),
            Data(effectiveKeepPolicy.rawValue.utf8),
            Data((metadataMoveAllowed ? "metadata-move" : "metadata-fixed").utf8),
            Data((projectedConflict ? "conflict" : "normal").utf8),
            Data(([model.canRead, model.canWrite, model.canAddChildren, model.canTrash, model.canDelete, model.trashed, model.tombstone].map { $0 ? "1" : "0" }.joined()).utf8),
        ])
        self.itemVersion = NSFileProviderItemVersion(contentVersion: model.version.content, metadataVersion: VersionHasher.digest([model.version.metadata, projectionBoundary]))
        self.userInfo = [
            "authenticated": projectedAuthenticated,
            "trashed": model.trashed,
            "tombstone": model.tombstone,
            "hasConflict": projectedConflict,
            "isUploaded": projectedUploaded,
            "isUploading": uploadPending,
            "isDownloading": downloadPending,
            "isDownloaded": projectedDownloaded,
            "keepDownloaded": effectiveKeepPolicy == .keepDownloaded,
            "canEvict": canEvict,
            "canManageDownloadPolicy": canManageDownloadPolicy
        ]
        self.fileSystemFlags = Self.fileSystemFlags(for: model)
        self.isUploaded = projectedUploaded
        self.isUploading = uploadPending
        self.uploadingError = Self.error(for: projection?.localState.uploadError)
        self.isDownloaded = projectedDownloaded
        self.isDownloading = downloadPending
        self.downloadingError = Self.error(for: projection?.localState.downloadError)
        self.isMostRecentVersionDownloaded = projectedDownloaded && !downloadPending
        self.isShared = false
        self.isSharedByCurrentUser = false
        var decorationIDs: [NSFileProviderItemDecorationIdentifier] = []
        if projectedConflict { decorationIDs.append(NSFileProviderItemDecorationIdentifier("ai.tiy.nimbussync.conflict")) }
        if self.uploadingError != nil || self.downloadingError != nil { decorationIDs.append(NSFileProviderItemDecorationIdentifier("ai.tiy.nimbussync.error")) }
        if effectiveKeepPolicy == .keepDownloaded { decorationIDs.append(NSFileProviderItemDecorationIdentifier("ai.tiy.nimbussync.keep-downloaded")) }
        self.decorations = decorationIDs.isEmpty ? nil : decorationIDs
    }

    public convenience init(projection: ItemProjection) {
        self.init(model: projection.item, projection: projection)
    }

    /// POSIX permission bits shown on disk. Implementing this property and
    /// returning `[]` strips every user bit (folders surfaced as mode 0100,
    /// so Finder showed a no-access badge and refused to open them).
    /// Capabilities still gate each File Provider operation; these bits only
    /// have to stay consistent with them.
    public static func fileSystemFlags(for model: RemoteItem) -> NSFileProviderFileSystemFlags {
        var flags: NSFileProviderFileSystemFlags = []
        if model.canRead { flags.insert(.userReadable) }
        switch model.kind {
        case .folder:
            flags.insert(.userExecutable)
            if model.canAddChildren || model.canWrite { flags.insert(.userWritable) }
        case .file, .symlink, .unsupported:
            if model.canWrite { flags.insert(.userWritable) }
        }
        return flags
    }

    private static func error(for message: String?) -> Error? {
        guard let message, !message.isEmpty else { return nil }
        return NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.cannotSynchronize.rawValue, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

public protocol FileProviderBackend: AnyObject, Sendable {
    func item(identifier: String) throws -> RemoteItem?
    func children(parentIdentifier: String) throws -> [RemoteItem]
    func childrenPage(parentIdentifier: String, offset: Int, limit: Int) throws -> DirectoryPage
    func trashItems() throws -> [RemoteItem]
    func content(identifier: String, expectedVersion: Data?) throws -> Data
    func fetchContent(identifier: String, expectedVersion: Data?, to destination: URL) throws -> RemoteItem
    func create(template: RemoteItem, content: Data?, replayKey: String) throws -> RemoteItem
    func modify(item: RemoteItem, expectedVersion: Data?, changedFields: NSFileProviderItemFields, content: Data?, replayKey: String) throws -> RemoteItem
    func trash(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem
    func restore(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem
    func delete(identifier: String, expectedVersion: Data?, recursive: Bool) throws
}

public protocol SnapshotAwareFileProviderBackend: FileProviderBackend {
    func childrenPage(parentIdentifier: String, offset: Int, limit: Int, snapshotID: String, generation: UInt64) throws -> DirectoryPage
}

public extension FileProviderBackend {
    func childrenPage(parentIdentifier: String, offset: Int, limit: Int) throws -> DirectoryPage {
        let all = try children(parentIdentifier: parentIdentifier)
        let boundedLimit = max(1, min(limit, 500))
        let slice = Array(all.dropFirst(max(0, offset)).prefix(boundedLimit))
        let next = offset + slice.count < all.count ? offset + slice.count : nil
        return DirectoryPage(items: slice, nextOffset: next, generation: 1, complete: next == nil)
    }

    /// Production backends override this with bounded streaming. The default
    /// implementation keeps test doubles small while preserving the callback
    /// contract used by the extension.
    func fetchContent(identifier: String, expectedVersion: Data?, to destination: URL) throws -> RemoteItem {
        let data = try content(identifier: identifier, expectedVersion: expectedVersion)
        guard let item = try item(identifier: identifier) else { throw CoreFailure(code: .notFound, retryable: false) }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var offset = 0
        let blockSize = 1024 * 1024
        while offset < data.count {
            let end = min(data.count, offset + blockSize)
            try handle.write(contentsOf: data[offset..<end])
            offset = end
        }
        return item
    }

    func trash(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
    func restore(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
    func trashItems() throws -> [RemoteItem] { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
}

public final class StoreFileProviderBackend: FileProviderBackend, @unchecked Sendable {
    private let store: SQLiteStateStore
    public init(store: SQLiteStateStore) { self.store = store }
    public func item(identifier: String) throws -> RemoteItem? { try store.item(identifier: identifier) }
    public func children(parentIdentifier: String) throws -> [RemoteItem] { try store.listChildren(parentIdentifier: parentIdentifier) }
    public func childrenPage(parentIdentifier: String, offset: Int, limit: Int) throws -> DirectoryPage { try store.listChildrenPage(parentIdentifier: parentIdentifier, offset: offset, limit: limit) }
    public func content(identifier: String, expectedVersion: Data?) throws -> Data { throw CoreFailure(code: .network, retryable: true) }
    public func fetchContent(identifier: String, expectedVersion: Data?, to destination: URL) throws -> RemoteItem { throw CoreFailure(code: .network, retryable: true) }
    public func create(template: RemoteItem, content: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
    public func modify(item: RemoteItem, expectedVersion: Data?, changedFields: NSFileProviderItemFields, content: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
    public func trash(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
    public func restore(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
    public func delete(identifier: String, expectedVersion: Data?, recursive: Bool) throws { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
}

/// Used when the shared App Group or Domain database cannot be opened. A
/// File Provider callback must fail closed in this state rather than serving
/// detached in-memory data that disappears with the extension process.
public final class UnavailableFileProviderBackend: FileProviderBackend, @unchecked Sendable {
    public init() {}
    public func item(identifier: String) throws -> RemoteItem? { throw CoreFailure(code: .database, retryable: false, userActionRequired: true) }
    public func children(parentIdentifier: String) throws -> [RemoteItem] { throw CoreFailure(code: .database, retryable: false, userActionRequired: true) }
    public func childrenPage(parentIdentifier: String, offset: Int, limit: Int) throws -> DirectoryPage { throw CoreFailure(code: .database, retryable: false, userActionRequired: true) }
    public func content(identifier: String, expectedVersion: Data?) throws -> Data { throw CoreFailure(code: .database, retryable: false, userActionRequired: true) }
    public func fetchContent(identifier: String, expectedVersion: Data?, to destination: URL) throws -> RemoteItem { throw CoreFailure(code: .database, retryable: false, userActionRequired: true) }
    public func create(template: RemoteItem, content: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .database, retryable: false, userActionRequired: true) }
    public func modify(item: RemoteItem, expectedVersion: Data?, changedFields: NSFileProviderItemFields, content: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .database, retryable: false, userActionRequired: true) }
    public func trash(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .database, retryable: false, userActionRequired: true) }
    public func restore(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .database, retryable: false, userActionRequired: true) }
    public func delete(identifier: String, expectedVersion: Data?, recursive: Bool) throws { throw CoreFailure(code: .database, retryable: false, userActionRequired: true) }
}

public final class MemoryFileProviderBackend: FileProviderBackend, @unchecked Sendable {
    private var values: [String: RemoteItem]
    private var contents: [String: Data]
    private let lock = NSLock()
    public init(items: [RemoteItem] = [], contents: [String: Data] = [:]) { self.values = Dictionary(uniqueKeysWithValues: items.map { ($0.itemIdentifier, $0) }); self.contents = contents }
    public func item(identifier: String) throws -> RemoteItem? { lock.lock(); defer { lock.unlock() }; return values[identifier] }
    public func children(parentIdentifier: String) throws -> [RemoteItem] { lock.lock(); defer { lock.unlock() }; return values.values.filter { $0.parentIdentifier == parentIdentifier && !$0.tombstone && !$0.trashed }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    public func childrenPage(parentIdentifier: String, offset: Int, limit: Int) throws -> DirectoryPage { let all = try children(parentIdentifier: parentIdentifier); let boundedLimit = max(1, min(limit, 500)); let slice = Array(all.dropFirst(max(0, offset)).prefix(boundedLimit)); let next = offset + slice.count < all.count ? offset + slice.count : nil; return DirectoryPage(items: slice, nextOffset: next, generation: 1, complete: next == nil) }
    public func content(identifier: String, expectedVersion: Data?) throws -> Data { lock.lock(); defer { lock.unlock() }; guard let value = values[identifier], let data = contents[identifier] else { throw CoreFailure(code: .notFound, retryable: false) }; if let expectedVersion, expectedVersion != value.version.content { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }; return data }
    public func fetchContent(identifier: String, expectedVersion: Data?, to destination: URL) throws -> RemoteItem { let data = try content(identifier: identifier, expectedVersion: expectedVersion); guard let item = try self.item(identifier: identifier) else { throw CoreFailure(code: .notFound, retryable: false) }; try data.write(to: destination, options: .atomic); return item }
    public func create(template: RemoteItem, content: Data?, replayKey: String) throws -> RemoteItem {
        lock.lock()
        defer { lock.unlock() }
        if let existing = values.values.first(where: { $0.parentIdentifier == template.parentIdentifier && $0.name.caseInsensitiveCompare(template.name) == .orderedSame }) {
            if existing.itemIdentifier == template.itemIdentifier { return existing }
            throw CoreFailure(code: .nameCollision, retryable: false, userActionRequired: true)
        }
        var item = template
        item.remoteID = item.remoteID ?? "remote-\(item.itemIdentifier)"
        if let content {
            item.size = Int64(content.count)
            item.version = ItemVersion(content: VersionHasher.content(primaryEntity: "\(content.count)-\(replayKey)"), metadata: item.version.metadata)
        }
        values[item.itemIdentifier] = item
        contents[item.itemIdentifier] = content ?? Data()
        return item
    }
    public func modify(item: RemoteItem, expectedVersion: Data?, changedFields: NSFileProviderItemFields, content: Data?, replayKey: String) throws -> RemoteItem {
        lock.lock()
        defer { lock.unlock() }
        guard var current = values[item.itemIdentifier] else { throw CoreFailure(code: .notFound, retryable: false) }
        if let expectedVersion, current.version.content != expectedVersion { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }
        if changedFields.contains(.contents) {
            guard let content else { throw CoreFailure(code: .unsupportedMetadata, retryable: false) }
            contents[item.itemIdentifier] = content
            current.version = ItemVersion(content: VersionHasher.content(primaryEntity: "\(content.count)-\(replayKey)"), metadata: current.version.metadata)
            current.size = Int64(content.count)
        }
        if changedFields.contains(.filename) {
            guard !values.values.contains(where: { $0.itemIdentifier != current.itemIdentifier && $0.parentIdentifier == current.parentIdentifier && $0.name.caseInsensitiveCompare(item.name) == .orderedSame }) else {
                throw CoreFailure(code: .nameCollision, retryable: false, userActionRequired: true)
            }
            current.name = item.name
            current.uri = rebuiltURI(parentIdentifier: current.parentIdentifier, name: current.name)
        }
        if changedFields.contains(.parentItemIdentifier) {
            guard !values.values.contains(where: { $0.itemIdentifier != current.itemIdentifier && $0.parentIdentifier == item.parentIdentifier && $0.name.caseInsensitiveCompare(current.name) == .orderedSame }) else {
                throw CoreFailure(code: .nameCollision, retryable: false, userActionRequired: true)
            }
            current.parentIdentifier = item.parentIdentifier
            current.uri = rebuiltURI(parentIdentifier: current.parentIdentifier, name: current.name)
        }
        values[item.itemIdentifier] = current
        return current
    }
    public func trash(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { lock.lock(); defer { lock.unlock() }; guard var current = values[item.itemIdentifier] else { throw CoreFailure(code: .notFound, retryable: false) }; if let expectedVersion, current.version.content != expectedVersion { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }; current.trashed = true; current.trashOriginalParentIdentifier = current.parentIdentifier; current.parentIdentifier = NSFileProviderItemIdentifier.trashContainer.rawValue; values[item.itemIdentifier] = current; return current }
    public func restore(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { lock.lock(); defer { lock.unlock() }; guard var current = values[item.itemIdentifier] else { throw CoreFailure(code: .notFound, retryable: false) }; if let expectedVersion, current.version.content != expectedVersion { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }; current.trashed = false; current.parentIdentifier = current.trashOriginalParentIdentifier ?? item.parentIdentifier; current.trashOriginalParentIdentifier = nil; values[item.itemIdentifier] = current; return current }
    public func delete(identifier: String, expectedVersion: Data?, recursive: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let current = values[identifier] else { return }
        if let expectedVersion, current.version.content != expectedVersion { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }
        let directChildren = values.values.filter { $0.parentIdentifier == identifier }
        if !recursive && !directChildren.isEmpty { throw CoreFailure(code: .directoryNotEmpty, retryable: false) }
        var identifiers = [identifier]
        if recursive {
            var index = 0
            while index < identifiers.count {
                let parent = identifiers[index]
                identifiers.append(contentsOf: values.values.filter { $0.parentIdentifier == parent }.map(\.itemIdentifier))
                index += 1
            }
        }
        for value in identifiers {
            values.removeValue(forKey: value)
            contents.removeValue(forKey: value)
        }
    }

    public func trashItems() throws -> [RemoteItem] {
        lock.lock()
        defer { lock.unlock() }
        return values.values.filter { $0.trashed && $0.parentIdentifier == NSFileProviderItemIdentifier.trashContainer.rawValue && !$0.tombstone }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func rebuiltURI(parentIdentifier: String?, name: String) -> String {
        guard let parentIdentifier, parentIdentifier != NSFileProviderItemIdentifier.rootContainer.rawValue, let parent = values[parentIdentifier] else { return "/\(name)" }
        return parent.uri == "/" ? "/\(name)" : "\(parent.uri)/\(name)"
    }
}

public enum FileProviderContainerKind: String, Sendable {
    case root
    case directory
    case workingSet
    case trash
}

private final class EnumerationObserverBox: @unchecked Sendable {
    let value: NSFileProviderEnumerationObserver
    init(_ value: NSFileProviderEnumerationObserver) { self.value = value }
}

private final class ChangeObserverBox: @unchecked Sendable {
    let value: NSFileProviderChangeObserver
    init(_ value: NSFileProviderChangeObserver) { self.value = value }
}

open class NimbusSyncFileProviderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let parentIdentifier: String
    private let domainIdentifier: String
    private let store: SQLiteStateStore?
    private let backend: FileProviderBackend
    private let containerKind: FileProviderContainerKind
    private let enumerationTaskBox = TaskCancellationBox()
    private var invalidated = false

    public init(parentIdentifier: String, domainIdentifier: String, store: SQLiteStateStore?, backend: FileProviderBackend, containerKind: FileProviderContainerKind = .directory) {
        self.parentIdentifier = parentIdentifier
        self.domainIdentifier = domainIdentifier
        self.store = store
        self.backend = backend
        self.containerKind = containerKind
    }

    public func invalidate() {
        invalidated = true
        enumerationTaskBox.cancel()
    }

    public func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        guard !invalidated else { return }
        if (containerKind == .root || containerKind == .directory), let asyncBackend = backend as? any CloudreveAsyncBackend {
            let observerBox = EnumerationObserverBox(observer)
            let task = Task { [self, observerBox] in
                await self.enumerateDirectoryAsync(for: observerBox.value, startingAt: page, backend: asyncBackend)
            }
            enumerationTaskBox.install(task)
            return
        }
        if containerKind == .trash, let asyncBackend = backend as? any CloudreveAsyncBackend {
            let observerBox = EnumerationObserverBox(observer)
            let task = Task { [self, observerBox] in
                await self.enumerateTrashAsync(for: observerBox.value, startingAt: page, backend: asyncBackend)
            }
            enumerationTaskBox.install(task)
            return
        }
        let observerBox = EnumerationObserverBox(observer)
        DispatchQueue.global(qos: .userInitiated).async { [self, observerBox] in
            self.enumerateItemsOnWorker(for: observerBox.value, startingAt: page)
        }
    }

    private func enumerateDirectoryAsync(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage, backend: any CloudreveAsyncBackend) async {
        guard !invalidated else { return }
        do {
            try store?.assertProcessUsable()
            let rawPage = Data(page as NSData)
            let initialByDate = Data(NSFileProviderPage.initialPageSortedByDate as NSData)
            let initialByName = Data(NSFileProviderPage.initialPageSortedByName as NSData)
            let isInitial = rawPage.isEmpty || rawPage == initialByDate || rawPage == initialByName
            let pageToken: PageToken?
            if isInitial {
                pageToken = nil
            } else {
                do {
                    let decoded = try PageToken.decode(rawPage)
                    try decoded.validate(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier)
                    pageToken = decoded
                } catch {
                    throw StoreBridgeError.pageTokenInvalid
                }
            }
            let cursor = pageToken.map { PageCursor(generation: $0.snapshotGeneration, opaqueCursor: Data(String($0.offset).utf8), snapshotID: $0.snapshotID, expiresAt: $0.expiresAt) }
            let systemDomain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(domainIdentifier), displayName: "NimbusSync")
            guard let manager = NSFileProviderManager(for: systemDomain) else {
                throw CoreFailure(code: .database, retryable: true, userActionRequired: true)
            }
            let context = FileProviderOperationContext(
                itemIdentifier: NSFileProviderItemIdentifier(parentIdentifier),
                progress: Progress(totalUnitCount: 1),
                registrar: FileProviderManagerTaskRegistrar(manager: manager),
                cancellation: CancellationToken()
            )
            let remotePage = try await backend.childrenPage(parentIdentifier: parentIdentifier, cursor: cursor, context: context)
            guard !invalidated, !Task.isCancelled else { return }
            if let pageToken, let nextCursor = remotePage.nextCursor, pageToken.snapshotGeneration != nextCursor.generation {
                throw StoreBridgeError.pageTokenInvalid
            }
            if let store, CloudreveIdentifier.validate(parentIdentifier, prefix: CloudreveIdentifier.itemPrefix) {
                try store.markVisitedContainer(parentIdentifier)
            }
            observer.didEnumerate(try remotePage.items.map(projectedItem))
            guard let nextCursor = remotePage.nextCursor else {
                observer.finishEnumerating(upTo: nil)
                return
            }
            let nextOffset = Int(String(data: nextCursor.opaqueCursor ?? Data(), encoding: .utf8) ?? "0") ?? 0
            let next = try PageToken(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier, snapshotGeneration: nextCursor.generation, offset: nextOffset, snapshotID: nextCursor.snapshotID ?? remotePage.snapshotID, expiresAt: nextCursor.expiresAt ?? remotePage.expiresAt).encoded()
            observer.finishEnumerating(upTo: NSFileProviderPage(next))
        } catch {
            observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error))
        }
    }

    private func enumerateTrashAsync(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage, backend: any CloudreveAsyncBackend) async {
        do {
            try store?.assertProcessUsable()
            let rawPage = Data(page as NSData)
            let initialByDate = Data(NSFileProviderPage.initialPageSortedByDate as NSData)
            let initialByName = Data(NSFileProviderPage.initialPageSortedByName as NSData)
            let isInitial = rawPage.isEmpty || rawPage == initialByDate || rawPage == initialByName
            let pageToken: PageToken?
            if isInitial {
                pageToken = nil
            } else {
                do {
                    let decoded = try PageToken.decode(rawPage)
                    try decoded.validate(domainIdentifier: domainIdentifier, parentIdentifier: NSFileProviderItemIdentifier.trashContainer.rawValue)
                    guard !decoded.isWorkingSet else { throw StoreBridgeError.pageTokenInvalid }
                    pageToken = decoded
                } catch let error as StoreBridgeError {
                    throw error
                } catch {
                    throw StoreBridgeError.pageTokenInvalid
                }
            }
            let systemDomain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(domainIdentifier), displayName: "NimbusSync")
            guard let manager = NSFileProviderManager(for: systemDomain) else {
                throw CoreFailure(code: .database, retryable: true, userActionRequired: true)
            }
            let context = FileProviderOperationContext(
                itemIdentifier: .trashContainer,
                progress: Progress(totalUnitCount: 1),
                registrar: FileProviderManagerTaskRegistrar(manager: manager),
                cancellation: CancellationToken()
            )
            let allItems = try await backend.trashItems(context: context)
            guard !invalidated, !Task.isCancelled else { return }
            let sortedItems = allItems.sorted { $0.itemIdentifier < $1.itemIdentifier }
            let start: Int
            if let lastItemIdentifier = pageToken?.lastItemIdentifier {
                start = sortedItems.firstIndex(where: { $0.itemIdentifier > lastItemIdentifier }) ?? sortedItems.count
            } else {
                // Accept v2 offset tokens emitted before Trash switched to
                // keyset pagination; all newly emitted tokens are keysets.
                start = min(max(0, pageToken?.offset ?? 0), sortedItems.count)
            }
            let limit = boundedPageSize(observer.suggestedPageSize)
            let items = Array(sortedItems.dropFirst(start).prefix(limit))
            observer.didEnumerate(try items.map(projectedItem))
            if start + items.count < sortedItems.count, let lastItemIdentifier = items.last?.itemIdentifier {
                let next = try PageToken(domainIdentifier: domainIdentifier, parentIdentifier: NSFileProviderItemIdentifier.trashContainer.rawValue, snapshotGeneration: 1, offset: 0, sort: "item_uuid", lastItemIdentifier: lastItemIdentifier).encoded()
                observer.finishEnumerating(upTo: NSFileProviderPage(next))
            } else {
                observer.finishEnumerating(upTo: nil)
            }
        } catch {
            observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error))
        }
    }

    private func enumerateItemsOnWorker(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        guard !invalidated else { return }
        do {
            try store?.assertProcessUsable()
            let rawPage = Data(page as NSData)
            let initialByDate = Data(NSFileProviderPage.initialPageSortedByDate as NSData)
            let initialByName = Data(NSFileProviderPage.initialPageSortedByName as NSData)
            let isInitial = rawPage.isEmpty || rawPage == initialByDate || rawPage == initialByName
            let pageToken: PageToken?
            if isInitial {
                pageToken = nil
            } else {
                do { pageToken = try PageToken.decode(rawPage) }
                catch { throw StoreBridgeError.pageTokenInvalid }
            }
            switch containerKind {
            case .workingSet:
                try enumerateWorkingSet(observer: observer, pageToken: pageToken)
            case .trash:
                try enumerateTrash(observer: observer, pageToken: pageToken)
            case .root, .directory:
                try enumerateDirectory(observer: observer, pageToken: pageToken)
            }
        } catch let error as StoreBridgeError { observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error)) }
        catch { observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error)) }
    }

    private func enumerateWorkingSet(observer: NSFileProviderEnumerationObserver, pageToken: PageToken?) throws {
        guard pageToken?.isWorkingSet ?? true else { throw StoreBridgeError.pageTokenInvalid }
        guard let store else { throw CoreFailure(code: .database, retryable: false, userActionRequired: true) }
        if let pageToken {
            do {
                try pageToken.validate(domainIdentifier: domainIdentifier, parentIdentifier: NSFileProviderItemIdentifier.workingSet.rawValue)
            } catch {
                throw StoreBridgeError.pageTokenInvalid
            }
            // Keyset pagination over item_uuid is stable under concurrent
            // writes, and anything that changes mid-enumeration is delivered
            // by enumerateChanges from the anchor captured before the first
            // page. Rejecting tokens on every working-set revision bump (each
            // visit, download or pending flip) livelocked large initial syncs.
        }
        let limit = boundedPageSize(observer.suggestedPageSize)
        let items = try store.workingSetItems(afterIdentifier: pageToken?.lastItemIdentifier, limit: limit)
        observer.didEnumerate(try items.map(projectedItem))
        guard items.count == limit, let last = items.last?.itemIdentifier else {
            observer.finishEnumerating(upTo: nil)
            return
        }
        let revision = try store.workingSetRevision()
        let next = try PageToken.workingSet(domainIdentifier: domainIdentifier, lastItemIdentifier: last, workingSetRevision: revision).encoded()
        observer.finishEnumerating(upTo: NSFileProviderPage(next))
    }

    private func enumerateDirectory(observer: NSFileProviderEnumerationObserver, pageToken: PageToken?) throws {
        if let pageToken {
            guard !pageToken.isWorkingSet else { throw StoreBridgeError.pageTokenInvalid }
            do {
                try pageToken.validate(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier)
            } catch {
                throw StoreBridgeError.pageTokenInvalid
            }
        }
        let offset = pageToken?.offset ?? 0
        let limit = boundedPageSize(observer.suggestedPageSize)
        let pageResult: DirectoryPage
        if let pageToken, let snapshotID = pageToken.snapshotID, let snapshotBackend = backend as? any SnapshotAwareFileProviderBackend {
            pageResult = try snapshotBackend.childrenPage(parentIdentifier: parentIdentifier, offset: offset, limit: limit, snapshotID: snapshotID, generation: pageToken.snapshotGeneration)
        } else {
            pageResult = try backend.childrenPage(parentIdentifier: parentIdentifier, offset: offset, limit: limit)
        }
        if let pageToken, pageToken.snapshotGeneration != pageResult.generation {
            throw StoreBridgeError.pageTokenInvalid
        }
        if let pageToken, let tokenSnapshot = pageToken.snapshotID, tokenSnapshot != pageResult.snapshotID {
            throw StoreBridgeError.pageTokenInvalid
        }
        if let store, CloudreveIdentifier.validate(parentIdentifier, prefix: CloudreveIdentifier.itemPrefix) {
            try store.markVisitedContainer(parentIdentifier)
        }
        observer.didEnumerate(try pageResult.items.map(projectedItem))
        if let nextOffset = pageResult.nextOffset {
            let next = try PageToken(
                domainIdentifier: domainIdentifier,
                parentIdentifier: parentIdentifier,
                snapshotGeneration: pageResult.generation,
                offset: nextOffset,
                snapshotID: pageResult.snapshotID,
                expiresAt: pageResult.expiresAt.map { Int64($0.timeIntervalSince1970) }
            ).encoded()
            observer.finishEnumerating(upTo: NSFileProviderPage(next))
        } else {
            observer.finishEnumerating(upTo: nil)
        }
    }

    private func enumerateTrash(observer: NSFileProviderEnumerationObserver, pageToken: PageToken?) throws {
        if let pageToken {
            guard !pageToken.isWorkingSet else { throw StoreBridgeError.pageTokenInvalid }
            do {
                try pageToken.validate(domainIdentifier: domainIdentifier, parentIdentifier: NSFileProviderItemIdentifier.trashContainer.rawValue)
            } catch {
                throw StoreBridgeError.pageTokenInvalid
            }
        }
        let allItems = try backend.trashItems()
        let sortedItems = allItems.sorted { $0.itemIdentifier < $1.itemIdentifier }
        let start: Int
        if let lastItemIdentifier = pageToken?.lastItemIdentifier {
            start = sortedItems.firstIndex(where: { $0.itemIdentifier > lastItemIdentifier }) ?? sortedItems.count
        } else {
            start = min(max(0, pageToken?.offset ?? 0), sortedItems.count)
        }
        let limit = boundedPageSize(observer.suggestedPageSize)
        let items = Array(sortedItems.dropFirst(start).prefix(limit))
        observer.didEnumerate(try items.map(projectedItem))
        if start + items.count < sortedItems.count, let lastItemIdentifier = items.last?.itemIdentifier {
            let next = try PageToken(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier, snapshotGeneration: 1, offset: 0, sort: "item_uuid", lastItemIdentifier: lastItemIdentifier).encoded()
            observer.finishEnumerating(upTo: NSFileProviderPage(next))
        } else {
            observer.finishEnumerating(upTo: nil)
        }
    }

    private func boundedPageSize(_ suggested: Int?) -> Int {
        let value = suggested ?? 200
        return max(1, min(value > 0 ? value : 200, 4_000))
    }

    private func projectedItem(_ item: RemoteItem) throws -> NSFileProviderItem {
        var authenticated: Bool?
        if let store {
            do {
                authenticated = try store.domain(identifier: domainIdentifier).map { $0.status != .authExpired } ?? false
            } catch {
                authenticated = false
            }
        }
        if let store, let projection = try store.itemProjection(identifier: item.itemIdentifier) {
            if projection.item == item {
                return NimbusSyncFileProviderItem(model: projection.item, projection: projection, authenticated: authenticated)
            }
            let mergedProjection = ItemProjection(item: item, localState: projection.localState, effectiveKeepPolicy: projection.effectiveKeepPolicy, metadataMoveAllowed: projection.metadataMoveAllowed, operationState: projection.operationState, childItemCount: projection.childItemCount, hasConflict: projection.hasConflict)
            return NimbusSyncFileProviderItem(model: item, projection: mergedProjection, authenticated: authenticated)
        }
        return NimbusSyncFileProviderItem(model: item, authenticated: authenticated)
    }

    public func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        guard !invalidated else { return }
        guard let store else {
            observer.finishEnumeratingWithError(FileProviderErrorMapper.map(CoreFailure(code: .database, retryable: false, userActionRequired: true)))
            return
        }
        do {
            try store.assertProcessUsable()
        } catch {
            observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error))
            return
        }
        let observerBox = ChangeObserverBox(observer)
        DispatchQueue.global(qos: .userInitiated).async { [self, observerBox] in
            self.enumerateChangesOnWorker(for: observerBox.value, from: syncAnchor, store: store)
        }
    }

    private func enumerateChangesOnWorker(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor, store: SQLiteStateStore) {
        guard !invalidated else { return }
        do {
            try store.assertProcessUsable()
            let anchor: SyncAnchor
            do { anchor = try SyncAnchor.decode(Data(syncAnchor as NSData)) }
            catch { throw StoreBridgeError.anchorExpired }
            let suggestedBatchSize = observer.suggestedBatchSize ?? 200
            let batch = try store.enumerateChanges(domainIdentifier: domainIdentifier, scope: parentIdentifier, from: anchor, limit: max(1, min(suggestedBatchSize > 0 ? suggestedBatchSize : 200, 4_000)))
            var updates: [NSFileProviderItem] = []
            var deletes: [NSFileProviderItemIdentifier] = []
            for change in orderedJournalChanges(collapsedJournalChanges(batch.changes)) {
                let kind = change.kind.lowercased()
                let leavesDirectory = containerKind != .workingSet && change.oldParentIdentifier == parentIdentifier && change.newParentIdentifier != parentIdentifier
                let leavesWorkingSet: Bool
                if containerKind == .workingSet && change.oldParentIdentifier != change.newParentIdentifier {
                    leavesWorkingSet = !(try store.isWorkingSetMember(identifier: change.itemIdentifier))
                } else {
                    leavesWorkingSet = false
                }
                if kind == "deleted" || kind == "delete" || kind == "view_removed" || leavesDirectory {
                    deletes.append(NSFileProviderItemIdentifier(change.itemIdentifier))
                } else if leavesWorkingSet {
                    deletes.append(NSFileProviderItemIdentifier(change.itemIdentifier))
                } else if let item = try? JSONDecoder().decode(RemoteItem.self, from: change.itemPayload) {
                    if item.tombstone {
                        deletes.append(NSFileProviderItemIdentifier(change.itemIdentifier))
                        continue
                    }
                    let localState = try store.localItemState(identifier: item.itemIdentifier)
                    let hasConflict = (try? store.hasPendingConflict(itemIdentifier: item.itemIdentifier)) ?? false
                    if let liveProjection = try store.itemProjection(identifier: item.itemIdentifier) {
                        let projection = ItemProjection(item: item, localState: localState, effectiveKeepPolicy: liveProjection.effectiveKeepPolicy, metadataMoveAllowed: liveProjection.metadataMoveAllowed, operationState: liveProjection.operationState, childItemCount: liveProjection.childItemCount, hasConflict: hasConflict)
                        updates.append(NimbusSyncFileProviderItem(projection: projection))
                    } else {
                        updates.append(NimbusSyncFileProviderItem(model: item, isDownloaded: localState.materialized, hasConflict: hasConflict))
                    }
                } else {
                    throw StoreBridgeError.schemaFenced
                }
            }
            ActivityLog.shared.debug("file-provider", enumeratedChangesSummary(
                scope: containerKind.rawValue,
                from: anchor.sequence,
                to: batch.nextAnchor.sequence,
                updated: updates.map { $0.itemIdentifier.rawValue },
                deleted: deletes.map(\.rawValue),
                hidden: batch.hiddenChanges,
                moreComing: batch.moreComing
            ))
            if !updates.isEmpty { observer.didUpdate(updates) }
            if !deletes.isEmpty { observer.didDeleteItems(withIdentifiers: deletes) }
            observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(try batch.nextAnchor.encoded()), moreComing: batch.moreComing)
        } catch { observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error)) }
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        guard let store else { completionHandler(nil); return }
        do { completionHandler(NSFileProviderSyncAnchor(try store.currentAnchor(domainIdentifier: domainIdentifier, scope: parentIdentifier).encoded())) } catch { completionHandler(nil) }
    }
}

/// What `item(for:)` may hand the system. A tombstoned row stays in the store for replay and
/// remote-identity bookkeeping, but the item is deleted. Answering with it undoes the deletion the
/// working set just announced: right after a failed download or update the system asks for the
/// item's metadata and keeps whatever it is told, so the stale item would come back every time.
func itemServableToSystem(_ item: RemoteItem?) throws -> RemoteItem {
    guard let item else { throw CoreFailure(code: .notFound, retryable: false) }
    guard !item.tombstone else { throw CoreFailure(code: .notFound, retryable: false, redactedContext: ["stage": "deleted_item"]) }
    return item
}

/// One debug line per change batch handed to the system: the journal range it covers and which
/// items it reports updated or deleted. Identifiers are shortened to their first 12 characters
/// (`cri-2cc9ed6d`) so a whole batch fits the activity log's line limit.
func enumeratedChangesSummary(scope: String, from: UInt64, to: UInt64, updated: [String], deleted: [String], hidden: Int, moreComing: Bool) -> String {
    var summary = "Changes enumerated · scope=\(scope) from=\(from) to=\(to) updates=\(updated.count) deletes=\(deleted.count) hidden=\(hidden) more=\(moreComing)"
    if !deleted.isEmpty { summary += " deleted=" + shortIdentifierList(deleted, limit: 20) }
    if !updated.isEmpty { summary += " updated=" + shortIdentifierList(updated, limit: 12) }
    return summary
}

func shortIdentifierList(_ identifiers: [String], limit: Int) -> String {
    let shown = identifiers.prefix(limit).map { String($0.prefix(12)) }.joined(separator: ",")
    return identifiers.count > limit ? shown + ",+\(identifiers.count - limit)" : shown
}

/// One batch can hold several commits for the same item; the system must only see its final
/// state. Keeps one change per item: the latest change's kind, payload and new parent, with the
/// old parent of the item's earliest change in the batch (first old parent, final new parent).
/// Items keep the order of their first appearance.
func collapsedJournalChanges(_ changes: [JournalChange]) -> [JournalChange] {
    var earliest: [String: JournalChange] = [:]
    var latest: [String: JournalChange] = [:]
    var order: [String] = []
    for change in changes {
        let identifier = change.itemIdentifier
        if let first = earliest[identifier] {
            if change.sequence < first.sequence { earliest[identifier] = change }
        } else {
            earliest[identifier] = change
            order.append(identifier)
        }
        if let last = latest[identifier], last.sequence > change.sequence { continue }
        latest[identifier] = change
    }
    return order.compactMap { identifier in
        guard let first = earliest[identifier], let last = latest[identifier] else { return nil }
        guard first.sequence != last.sequence else { return last }
        return JournalChange(sequence: last.sequence, epoch: last.epoch, itemIdentifier: identifier, oldParentIdentifier: first.oldParentIdentifier, newParentIdentifier: last.newParentIdentifier, kind: last.kind, version: last.version, origin: last.origin, providerVisible: last.providerVisible, itemPayload: last.itemPayload, itemVersion: last.itemVersion)
    }
}

func orderedJournalChanges(_ changes: [JournalChange]) -> [JournalChange] {
    changes.enumerated().sorted { left, right in
        let leftChange = left.element
        let rightChange = right.element
        let leftDelete = ["deleted", "delete", "view_removed"].contains(leftChange.kind.lowercased())
        let rightDelete = ["deleted", "delete", "view_removed"].contains(rightChange.kind.lowercased())
        if leftDelete != rightDelete { return !leftDelete }
        let leftDepth = journalPathDepth(leftChange)
        let rightDepth = journalPathDepth(rightChange)
        if leftDepth != rightDepth { return leftDelete ? leftDepth > rightDepth : leftDepth < rightDepth }
        if leftChange.itemIdentifier != rightChange.itemIdentifier { return leftChange.itemIdentifier < rightChange.itemIdentifier }
        return left.offset < right.offset
    }.map(\.element)
}

private func journalPathDepth(_ change: JournalChange) -> Int {
    guard let item = try? JSONDecoder().decode(RemoteItem.self, from: change.itemPayload) else { return 0 }
    return item.uri.split(separator: "/").count
}

public final class WorkingSetEnumerator: NimbusSyncFileProviderEnumerator, @unchecked Sendable {
    public init(domainIdentifier: String, store: SQLiteStateStore?, backend: FileProviderBackend) {
        super.init(parentIdentifier: NSFileProviderItemIdentifier.workingSet.rawValue, domainIdentifier: domainIdentifier, store: store, backend: backend, containerKind: .workingSet)
    }
}

public final class DirectoryEnumerator: NimbusSyncFileProviderEnumerator, @unchecked Sendable {
    public init(parentIdentifier: String, domainIdentifier: String, store: SQLiteStateStore?, backend: FileProviderBackend, root: Bool = false) {
        super.init(parentIdentifier: parentIdentifier, domainIdentifier: domainIdentifier, store: store, backend: backend, containerKind: root ? .root : .directory)
    }
}

public final class TrashEnumerator: NimbusSyncFileProviderEnumerator, @unchecked Sendable {
    public init(domainIdentifier: String, store: SQLiteStateStore?, backend: FileProviderBackend) {
        super.init(parentIdentifier: NSFileProviderItemIdentifier.trashContainer.rawValue, domainIdentifier: domainIdentifier, store: store, backend: backend, containerKind: .trash)
    }
}

private final class FetchCompletion: @unchecked Sendable {
    private let handler: (URL?, NSFileProviderItem?, Error?) -> Void
    private let lock = NSLock()
    private var finished = false
    init(_ handler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) { self.handler = handler }
    func call(_ url: URL?, _ item: NSFileProviderItem?, _ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        handler(url, item, error)
    }
}

private final class TaskCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

open class NimbusSyncFileProviderExtension: NSObject, NSFileProviderDomainState, NSFileProviderThumbnailing, NSFileProviderCustomAction, @unchecked Sendable {
    public let domain: NSFileProviderDomain
    private var store: SQLiteStateStore?
    private var backend: FileProviderBackend
    private let stateProjection: DomainStateProjection
    private let stateLock = NSLock()
    private var invalidated = false
    private var systemSetCoordinator: SystemSetCoordinator?
    private var cacheRefreshCoordinator: FrameworkCacheRefreshCoordinator?
    private var backgroundTask: Task<Void, Never>?
    private let reconciliationLogger = Logger(subsystem: "ai.tiy.nimbussync", category: "file-provider-reconciliation")

    @objc public required init(domain: NSFileProviderDomain) {
        self.domain = domain
        var resolvedStore: SQLiteStateStore?
        var resolvedBackend: FileProviderBackend = UnavailableFileProviderBackend()
        var authenticated = false
        if let databaseURL = try? AppGroupPaths.prepareDomain(domain.identifier.rawValue), let store = try? SQLiteStateStore(url: databaseURL) {
            resolvedStore = store
            let storedDomain: StoredDomain?
            do { storedDomain = try store.domain(identifier: domain.identifier.rawValue) } catch { storedDomain = nil }
            if let stored = storedDomain, let origin = URL(string: stored.origin) {
                let credentialVault = KeychainCredentialVault(accessGroup: KeychainAccessGroup.current())
                let secretVault = KeychainOpaqueSecretVault(accessGroup: KeychainAccessGroup.current())
                authenticated = (try? credentialVault.read(reference: stored.secretReference)) != nil
                resolvedBackend = NimbusSyncRemoteBackend(origin: origin, rootURI: stored.rootURI, store: store, vault: credentialVault, credentialReference: stored.secretReference, capabilitySnapshot: stored.capabilitySnapshot, providerName: stored.capabilitySnapshot.providers.first?.name ?? "unverified", secretVault: secretVault, domainIdentifier: domain.identifier.rawValue)
            }
        }
        self.store = resolvedStore
        self.backend = resolvedBackend
        if let resolvedStore {
            self.systemSetCoordinator = SystemSetCoordinator(store: resolvedStore, manager: NSFileProviderManager(for: domain), domainIdentifier: domain.identifier.rawValue)
            self.cacheRefreshCoordinator = FrameworkCacheRefreshCoordinator(store: resolvedStore, manager: NSFileProviderManager(for: domain), domainIdentifier: domain.identifier.rawValue)
        }
        if let stateURL = AppGroupPaths.domainVersionURL(domain.identifier.rawValue) {
            self.stateProjection = DomainStateProjection.load(from: stateURL, authenticated: authenticated)
        } else {
            self.stateProjection = DomainStateProjection(authenticated: authenticated)
        }
        super.init()
        backgroundTask = Task(priority: .utility) { [weak self] in
            // Journal/transfer compaction scans whole tables; keep it off the
            // extension launch path that every Finder callback waits on.
            try? self?.store?.compactJournal()
            try? self?.store?.compactTransferState()
            await self?.systemSetCoordinator?.drainRequiredRefreshes()
            guard let coordinator = self?.cacheRefreshCoordinator else { return }
            while !Task.isCancelled {
                guard let complete = try? await coordinator.refreshIfNeeded() else { return }
                if complete { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    public convenience init(domain: NSFileProviderDomain, store: SQLiteStateStore, backend: FileProviderBackend) {
        self.init(domain: domain)
        backgroundTask?.cancel()
        self.store = store
        self.backend = backend
        self.systemSetCoordinator = SystemSetCoordinator(store: store, manager: NSFileProviderManager(for: domain), domainIdentifier: domain.identifier.rawValue)
        self.cacheRefreshCoordinator = FrameworkCacheRefreshCoordinator(store: store, manager: NSFileProviderManager(for: domain), domainIdentifier: domain.identifier.rawValue)
        backgroundTask = Task { [weak self] in
            await self?.systemSetCoordinator?.drainRequiredRefreshes()
            guard let coordinator = self?.cacheRefreshCoordinator else { return }
            while !Task.isCancelled {
                guard let complete = try? await coordinator.refreshIfNeeded() else { return }
                if complete { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    @objc public func invalidate() {
        invalidated = true
        backgroundTask?.cancel()
        backgroundTask = nil
    }

    @objc public var domainVersion: NSFileProviderDomainVersion { stateLock.lock(); defer { stateLock.unlock() }; return stateProjection.domainVersion }
    @objc public var userInfo: [AnyHashable: Any] { stateLock.lock(); defer { stateLock.unlock() }; return stateProjection.userInfo }

    @objc(itemForIdentifier:request:completionHandler:)
    public func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completion = ItemCompletion(completionHandler)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, !self.invalidated, !progress.isCancelled else {
                completion.call(nil, FileProviderErrorMapper.map(CoreFailure(code: .cancelled, retryable: false)))
                return
            }
            if identifier == .rootContainer {
                do {
                    try self.store?.assertProcessUsable()
                } catch {
                    completion.call(nil, FileProviderErrorMapper.map(error))
                    return
                }
                completion.call(self.rootItem(), nil)
                progress.completedUnitCount = 1
                return
            }
            if identifier == .trashContainer {
                do {
                    try self.store?.assertProcessUsable()
                    guard let stored = try self.store?.domain(identifier: self.domain.identifier.rawValue), stored.capabilitySnapshot.canTrash else {
                        throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true)
                    }
                    completion.call(self.trashContainerItem(), nil)
                    progress.completedUnitCount = 1
                } catch {
                    completion.call(nil, FileProviderErrorMapper.map(error))
                }
                return
            }
            do {
                try self.store?.assertProcessUsable()
                let stored = try self.backend.item(identifier: identifier.rawValue)
                if stored?.tombstone == true {
                    ActivityLog.shared.debug("file-provider", "Answered a metadata request for a deleted item with noSuchItem · item=\(identifier.rawValue)")
                }
                let item = try itemServableToSystem(stored)
                let projection = try self.store?.itemProjection(identifier: identifier.rawValue)
                completion.call(NimbusSyncFileProviderItem(model: item, isDownloaded: projection?.localState.materialized ?? false, hasConflict: projection?.hasConflict ?? false, projection: projection, authenticated: self.currentAuthenticationState()), nil)
                progress.completedUnitCount = 1
            } catch {
                completion.call(nil, FileProviderErrorMapper.map(error))
            }
        }
        return progress
    }

    @objc(fetchContentsForItemWithIdentifier:version:request:completionHandler:)
    public func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let cancellation = FetchCompletion(completionHandler)
        let token = CancellationToken()
        let taskBox = TaskCancellationBox()
        progress.cancellationHandler = {
            taskBox.cancel()
            token.cancel()
            cancellation.call(nil, nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil))
        }
        let expectedVersion = requestedVersion?.contentVersion
        let backend = self.backend
        let store = self.store
        let domain = self.domain
        let task = Task {
            guard !progress.isCancelled else {
                cancellation.call(nil, nil, FileProviderErrorMapper.map(CoreFailure(code: .cancelled, retryable: false)))
                return
            }
            var temporaryURL: URL?
            var transferTask: TransferTaskSnapshot?
            do {
                let manager = NSFileProviderManager(for: domain)
                guard let manager, let directory = try? manager.temporaryDirectoryURL() else { throw CoreFailure(code: .network, retryable: true) }
                let url = directory.appendingPathComponent("nimbussync-\(UUID().uuidString).tmp")
                temporaryURL = url
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CoreFailure(code: .network, retryable: true) }
                let registrar: any URLSessionTaskRegistrar = FileProviderManagerTaskRegistrar(manager: manager)
                let context = FileProviderOperationContext(itemIdentifier: itemIdentifier, progress: progress, registrar: registrar, cancellation: token)
                let asyncBackend: any CloudreveAsyncBackend = (backend as? any CloudreveAsyncBackend) ?? LegacyAsyncFileProviderBackendAdapter(backend: backend)
                try store?.assertProcessUsable()
                try store?.setTransferState(identifier: itemIdentifier.rawValue, direction: "download", state: .running)
                if let store {
                    // This attempt answers for the item now; earlier failures are no longer news.
                    try? store.deleteFailedTransferTasks(itemIdentifier: itemIdentifier.rawValue, direction: "download")
                    transferTask = try? store.createTransferTask(operationID: nil, itemIdentifier: itemIdentifier.rawValue, direction: "download", totalBytes: nil)
                } else {
                    transferTask = nil
                }
                let item = try await asyncBackend.fetchContent(identifier: itemIdentifier.rawValue, expectedVersion: expectedVersion, destination: url, context: context)
                try token.throwIfCancelled()
                try store?.setMaterialized(itemIdentifier.rawValue, materialized: true)
                try store?.setTransferState(identifier: itemIdentifier.rawValue, direction: "download", state: .completed)
                if let transferTask {
                    try? store?.updateTransferTask(taskID: transferTask.taskID, state: "succeeded", bytes: item.size, totalBytes: item.size)
                }
                let projection = try store?.itemProjection(identifier: itemIdentifier.rawValue)
                cancellation.call(url, NimbusSyncFileProviderItem(model: item, isDownloaded: true, hasConflict: projection?.hasConflict ?? false, projection: projection), nil)
                progress.completedUnitCount = 1
            } catch {
                if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
                if (error as? CoreFailure)?.isAlreadyRegisteredTransfer == true {
                    // Finder asked for the same file twice at once. The download already running
                    // owns the item's state and its own task; this attempt leaves no trace.
                    if let transferTask { try? store?.deleteTransferTask(taskID: transferTask.taskID) }
                } else if (error as? CoreFailure)?.code == .cancelled || error is CancellationError {
                    // The user (or the system) cancelled the download; nothing failed.
                    try? store?.setTransferState(identifier: itemIdentifier.rawValue, direction: "download", state: .none)
                    if let transferTask { try? store?.deleteTransferTask(taskID: transferTask.taskID) }
                } else if (error as? CoreFailure)?.isRemoteIdentityChanged == true {
                    // The backend deleted the stale item; tell the system so it leaves Finder.
                    // Nothing is left to retry, so nothing is listed as an issue either.
                    try? store?.setTransferState(identifier: itemIdentifier.rawValue, direction: "download", state: .none)
                    if let transferTask { try? store?.deleteTransferTask(taskID: transferTask.taskID) }
                    do {
                        try await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
                        ActivityLog.shared.debug("file-provider", "Working set signalled for a stale item · item=\(itemIdentifier.rawValue)")
                    } catch {
                        ActivityLog.shared.debug("file-provider", "Working set signal failed for a stale item · item=\(itemIdentifier.rawValue) \(FileProviderErrorMapper.diagnosticSummary(error))")
                    }
                } else {
                    try? store?.setTransferState(identifier: itemIdentifier.rawValue, direction: "download", state: .failed, error: (error as? CoreFailure)?.code.rawValue ?? "download_failed")
                    if let transferTask {
                        try? store?.updateTransferTask(taskID: transferTask.taskID, state: "failed", bytes: 0, totalBytes: transferTask.totalBytes, errorCode: (error as? CoreFailure)?.code.rawValue ?? "download_failed")
                    }
                }
                cancellation.call(nil, nil, FileProviderErrorMapper.map(error))
            }
        }
        taskBox.install(task)
        return progress
    }

    @objc(createItemBasedOnTemplate:fields:contents:options:request:completionHandler:)
    public func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let templateIdentifier = itemTemplate.itemIdentifier.rawValue
        let completion = MutationCompletion(completionHandler)
        let token = CancellationToken()
        let taskBox = TaskCancellationBox()
        progress.cancellationHandler = { [weak self] in
            taskBox.cancel()
            token.cancel()
            try? self?.store?.requestCancel(itemIdentifier: CloudreveIdentifier.item(forTemplate: templateIdentifier))
            completion.call(nil, fields, false, FileProviderErrorMapper.map(CoreFailure(code: .cancelled, retryable: false)))
        }
        let model: RemoteItem
        do { model = try templateModel(itemTemplate) }
        catch {
            completion.call(nil, fields, false, FileProviderErrorMapper.map(error))
            return progress
        }
        let backend = self.backend
        let domain = self.domain
        let task = Task { [weak self] in
            guard let self, !progress.isCancelled else {
                completion.call(nil, fields, false, FileProviderErrorMapper.map(CoreFailure(code: .cancelled, retryable: false)))
                return
            }
            do {
                let manager = NSFileProviderManager(for: domain)
                guard let manager else { throw CoreFailure(code: .database, retryable: true) }
                let registrar: any URLSessionTaskRegistrar = FileProviderManagerTaskRegistrar(manager: manager)
                let context = FileProviderOperationContext(itemIdentifier: NSFileProviderItemIdentifier(model.itemIdentifier), progress: progress, registrar: registrar, cancellation: token)
                let asyncBackend: any CloudreveAsyncBackend = (backend as? any CloudreveAsyncBackend) ?? LegacyAsyncFileProviderBackendAdapter(backend: backend)
                let item = try await AsyncFileProviderMutationCoordinator(store: self.store, backend: asyncBackend).create(template: model, contents: url, fields: fields, options: options, context: context)
                self.advanceDomainState()
                let projection = try self.store?.itemProjection(identifier: item.itemIdentifier)
                completion.call(NimbusSyncFileProviderItem(model: item, projection: projection), [], false, nil)
                progress.completedUnitCount = 1
            } catch { completion.call(nil, fields, false, FileProviderErrorMapper.map(error)) }
        }
        taskBox.install(task)
        return progress
    }

    @objc(modifyItem:baseVersion:changedFields:contents:options:request:completionHandler:)
    public func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let itemIdentifier = item.itemIdentifier.rawValue
        let itemFilename = item.filename
        let itemParentIdentifier = item.parentItemIdentifier.rawValue
        let baseContentVersion = version.contentVersion
        let completion = MutationCompletion(completionHandler)
        let token = CancellationToken()
        let taskBox = TaskCancellationBox()
        progress.cancellationHandler = { [weak self] in
            taskBox.cancel()
            token.cancel()
            try? self?.store?.requestCancel(itemIdentifier: itemIdentifier)
            completion.call(nil, changedFields, false, FileProviderErrorMapper.map(CoreFailure(code: .cancelled, retryable: false)))
        }
        let backend = self.backend
        let domain = self.domain
        let task = Task { [weak self] in
            guard let self, !progress.isCancelled else {
                completion.call(nil, changedFields, false, FileProviderErrorMapper.map(CoreFailure(code: .cancelled, retryable: false)))
                return
            }
            do {
                guard var model = try backend.item(identifier: itemIdentifier) else { throw CoreFailure(code: .notFound, retryable: false) }
                if changedFields.contains(.filename) { model.name = itemFilename }
                if changedFields.contains(.parentItemIdentifier) { model.parentIdentifier = itemParentIdentifier }
                guard let manager = NSFileProviderManager(for: domain) else { throw CoreFailure(code: .database, retryable: true) }
                let registrar: any URLSessionTaskRegistrar = FileProviderManagerTaskRegistrar(manager: manager)
                let context = FileProviderOperationContext(itemIdentifier: NSFileProviderItemIdentifier(itemIdentifier), progress: progress, registrar: registrar, cancellation: token)
                let asyncBackend: any CloudreveAsyncBackend = (backend as? any CloudreveAsyncBackend) ?? LegacyAsyncFileProviderBackendAdapter(backend: backend)
                let outcome = try await AsyncFileProviderMutationCoordinator(store: self.store, backend: asyncBackend).modifyResolvingConflicts(item: model, baseVersion: baseContentVersion, fields: changedFields, contents: newContents, options: options, context: context)
                let updated = outcome.item
                self.advanceDomainState()
                let projection = try self.store?.itemProjection(identifier: updated.itemIdentifier)
                completion.call(NimbusSyncFileProviderItem(model: updated, projection: projection), self.unsupportedFields(changedFields), outcome.shouldFetchContent, nil)
                if outcome.conflictCopy != nil {
                    // Surface the preserved local copy next to the original.
                    try? await manager.signalEnumerator(for: .workingSet)
                }
                progress.completedUnitCount = 1
            } catch { completion.call(nil, changedFields, false, FileProviderErrorMapper.mapModifyError(error, options: options)) }
        }
        taskBox.install(task)
        return progress
    }

    @objc(deleteItemWithIdentifier:baseVersion:options:request:completionHandler:)
    public func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completion = DeleteCompletion(completionHandler)
        let token = CancellationToken()
        let taskBox = TaskCancellationBox()
        let itemIdentifier = identifier.rawValue
        let baseContentVersion = version.contentVersion
        progress.cancellationHandler = { [weak self] in
            taskBox.cancel()
            token.cancel()
            try? self?.store?.requestCancel(itemIdentifier: itemIdentifier)
            completion.call(FileProviderErrorMapper.map(CoreFailure(code: .cancelled, retryable: false)))
        }
        let backend = self.backend
        let domain = self.domain
        let task = Task { [weak self] in
            guard let self, !progress.isCancelled else {
                completion.call(FileProviderErrorMapper.map(CoreFailure(code: .cancelled, retryable: false)))
                return
            }
            do {
                guard let manager = NSFileProviderManager(for: domain) else { throw CoreFailure(code: .database, retryable: true) }
                let registrar: any URLSessionTaskRegistrar = FileProviderManagerTaskRegistrar(manager: manager)
                let context = FileProviderOperationContext(itemIdentifier: identifier, progress: progress, registrar: registrar, cancellation: token)
                let asyncBackend: any CloudreveAsyncBackend = (backend as? any CloudreveAsyncBackend) ?? LegacyAsyncFileProviderBackendAdapter(backend: backend)
                try await AsyncFileProviderMutationCoordinator(store: self.store, backend: asyncBackend).delete(itemIdentifier: itemIdentifier, baseVersion: baseContentVersion, recursive: options.contains(.recursive), context: context)
                self.advanceDomainState()
                completion.call(nil)
                progress.completedUnitCount = 1
            } catch { completion.call(FileProviderErrorMapper.map(error)) }
        }
        taskBox.install(task)
        return progress
    }

    @objc(enumeratorForContainerItemIdentifier:request:error:)
    public func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        try store?.assertProcessUsable()
        if containerItemIdentifier == .workingSet {
            return WorkingSetEnumerator(domainIdentifier: domain.identifier.rawValue, store: store, backend: backend)
        }
        if containerItemIdentifier == .trashContainer {
            guard let stored = try store?.domain(identifier: domain.identifier.rawValue), stored.capabilitySnapshot.canTrash else {
                throw FileProviderErrorMapper.map(CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true))
            }
            return TrashEnumerator(domainIdentifier: domain.identifier.rawValue, store: store, backend: backend)
        }
        let isRoot = containerItemIdentifier == .rootContainer
        let parent = isRoot ? NSFileProviderItemIdentifier.rootContainer.rawValue : containerItemIdentifier.rawValue
        return DirectoryEnumerator(parentIdentifier: parent, domainIdentifier: domain.identifier.rawValue, store: store, backend: backend, root: isRoot)
    }

    @objc(importDidFinishWithCompletionHandler:)
    public func importDidFinish(completionHandler: @escaping () -> Void) {
        try? store?.markSystemSetRefreshRequired("materialized")
        let completion = VoidCompletion(completionHandler)
        Task { [weak self] in
            _ = try? await self?.systemSetCoordinator?.refreshMaterialized()
            completion.call()
        }
    }
    @objc(materializedItemsDidChangeWithCompletionHandler:)
    public func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
        try? store?.markSystemSetRefreshRequired("materialized")
        let completion = VoidCompletion(completionHandler)
        Task { [weak self] in
            _ = try? await self?.systemSetCoordinator?.refreshMaterialized()
            completion.call()
        }
    }
    @objc(pendingItemsDidChangeWithCompletionHandler:)
    public func pendingItemsDidChange(completionHandler: @escaping () -> Void) {
        try? store?.markSystemSetRefreshRequired("pending")
        let completion = VoidCompletion(completionHandler)
        Task { [weak self] in
            _ = try? await self?.systemSetCoordinator?.refreshPending()
            completion.call()
        }
    }

    @objc(fetchThumbnailsForItemIdentifiers:requestedSize:perThumbnailCompletionHandler:completionHandler:)
    public func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize, perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void, completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        let completion = ErrorCompletion(completionHandler)
        let thumbnailCompletion = ThumbnailCompletion(perThumbnailCompletionHandler)
        let token = CancellationToken()
        let taskBox = TaskCancellationBox()
        progress.cancellationHandler = {
            taskBox.cancel()
            token.cancel()
            completion.call(FileProviderErrorMapper.map(CoreFailure(code: .cancelled, retryable: false)))
        }
        let backend = self.backend
        let store = self.store
        let domain = self.domain
        let task = Task {
            guard !progress.isCancelled else {
                completion.call(FileProviderErrorMapper.map(CoreFailure(code: .cancelled, retryable: false)))
                return
            }
            do {
                try store?.assertProcessUsable()
                if let asyncBackend = backend as? any CloudreveAsyncBackend {
                    guard let manager = NSFileProviderManager(for: domain),
                          let directory = try? manager.temporaryDirectoryURL() else {
                        throw CoreFailure(code: .database, retryable: true, userActionRequired: true)
                    }
                    let registrar: any URLSessionTaskRegistrar = FileProviderManagerTaskRegistrar(manager: manager)
                    for identifier in itemIdentifiers {
                        try token.throwIfCancelled()
                        let serverContext = FileProviderOperationContext(itemIdentifier: identifier, progress: Progress(totalUnitCount: 1), registrar: registrar, cancellation: token)
                        let serverThumbnail: ThumbnailFetchResult
                        do {
                            serverThumbnail = try await asyncBackend.thumbnail(identifier: identifier.rawValue, context: serverContext)
                        } catch let failure as CoreFailure where failure.code == .cancelled {
                            throw failure
                        } catch {
                            serverThumbnail = .unavailable
                        }
                        switch serverThumbnail {
                        case .image(let data):
                            thumbnailCompletion.call(identifier, makeThumbnail(data: data, size: size) ?? data, nil)
                            progress.completedUnitCount += 1
                            continue
                        case .unavailable:
                            thumbnailCompletion.call(identifier, nil, nil)
                            progress.completedUnitCount += 1
                            continue
                        case .unsupported:
                            break
                        }
                        guard let item = try backend.item(identifier: identifier.rawValue),
                              item.kind == .file,
                              item.size <= 8 * 1024 * 1024 else {
                            thumbnailCompletion.call(identifier, nil, nil)
                            progress.completedUnitCount += 1
                            continue
                        }
                        let destination = directory.appendingPathComponent("nimbussync-thumbnail-\(UUID().uuidString).tmp")
                        defer { try? FileManager.default.removeItem(at: destination) }
                        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                            thumbnailCompletion.call(identifier, nil, nil)
                            progress.completedUnitCount += 1
                            continue
                        }
                        do {
                            let context = FileProviderOperationContext(itemIdentifier: identifier, progress: progress, registrar: registrar, cancellation: token)
                            _ = try await asyncBackend.fetchContent(identifier: identifier.rawValue, expectedVersion: item.version.content, destination: destination, context: context)
                            let data = try Data(contentsOf: destination, options: .mappedIfSafe)
                            thumbnailCompletion.call(identifier, makeThumbnail(data: data, size: size), nil)
                        } catch let failure as CoreFailure where failure.code == .cancelled {
                            throw failure
                        } catch {
                            thumbnailCompletion.call(identifier, nil, nil)
                        }
                        progress.completedUnitCount += 1
                    }
                } else {
                    for identifier in itemIdentifiers {
                        try token.throwIfCancelled()
                        guard let item = try backend.item(identifier: identifier.rawValue),
                              item.kind == .file,
                              item.size <= 8 * 1024 * 1024 else {
                            thumbnailCompletion.call(identifier, nil, nil)
                            progress.completedUnitCount += 1
                            continue
                        }
                        do {
                            let data = try backend.content(identifier: identifier.rawValue, expectedVersion: item.version.content)
                            thumbnailCompletion.call(identifier, makeThumbnail(data: data, size: size), nil)
                        } catch {
                            thumbnailCompletion.call(identifier, nil, nil)
                        }
                        progress.completedUnitCount += 1
                    }
                }
                completion.call(nil)
            } catch {
                completion.call(FileProviderErrorMapper.map(error))
            }
        }
        taskBox.install(task)
        return progress
    }

    @objc(performActionWithIdentifier:onItemsWithIdentifiers:completionHandler:)
    public func performAction(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier, onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier], completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completion = ErrorCompletion(completionHandler)
        let supportedActions = [
            "ai.tiy.nimbussync.check-for-updates",
            "ai.tiy.nimbussync.keep-downloaded",
            "ai.tiy.nimbussync.allow-automatic-freeing",
            "ai.tiy.nimbussync.remove-download"
        ]
        guard supportedActions.contains(actionIdentifier.rawValue) else { completion.call(FileProviderErrorMapper.map(CoreFailure(code: .unsupportedMetadata, retryable: false))); return progress }
        let task = Task { [weak self] in
            guard let self, !progress.isCancelled else { completion.call(FileProviderErrorMapper.map(CoreFailure(code: .cancelled, retryable: false))); return }
            do {
                try self.store?.assertProcessUsable()
            } catch {
                completion.call(FileProviderErrorMapper.map(error))
                return
            }
            if actionIdentifier.rawValue == "ai.tiy.nimbussync.keep-downloaded" || actionIdentifier.rawValue == "ai.tiy.nimbussync.allow-automatic-freeing" {
                do {
                    guard let store = self.store else { throw CoreFailure(code: .database, retryable: false, userActionRequired: true) }
                    let policy: KeepDownloadedPolicy = actionIdentifier.rawValue == "ai.tiy.nimbussync.keep-downloaded" ? .keepDownloaded : .automatic
                    for identifier in itemIdentifiers {
                        guard !progress.isCancelled, !Task.isCancelled else {
                            throw CoreFailure(code: .cancelled, retryable: false)
                        }
                        guard identifier != .rootContainer,
                              let item = try store.item(identifier: identifier.rawValue),
                              item.canRead,
                              !item.tombstone,
                              !(try store.hasPendingWork(itemIdentifier: item.itemIdentifier)) else {
                            throw CoreFailure(code: .unsupportedMetadata, retryable: false, userActionRequired: true)
                        }
                        _ = try store.setKeepDownloadedPolicyAndJournal(identifier: identifier.rawValue, policy: policy)
                    }
                    self.advanceDomainState()
                    // The policy change is journaled with a new metadata version;
                    // the working-set delta carries the new contentPolicy and
                    // the system schedules the download itself. reimportItems
                    // is a recovery tool that re-imports whole subtrees.
                    if let manager = NSFileProviderManager(for: self.domain) {
                        try? await manager.signalEnumerator(for: .workingSet)
                    }
                    progress.completedUnitCount = 1
                    completion.call(nil)
                } catch { completion.call(FileProviderErrorMapper.map(error)) }
                return
            }
            if actionIdentifier.rawValue == "ai.tiy.nimbussync.remove-download" {
                do {
                    guard let manager = NSFileProviderManager(for: self.domain) else { throw CoreFailure(code: .database, retryable: true) }
                    for identifier in itemIdentifiers {
                        guard !progress.isCancelled, !Task.isCancelled else {
                            throw CoreFailure(code: .cancelled, retryable: false)
                        }
                        try await self.evict(identifier: identifier, manager: manager)
                        try? self.store?.setMaterialized(identifier.rawValue, materialized: false)
                    }
                    try? await manager.signalEnumerator(for: .workingSet)
                    progress.completedUnitCount = 1
                    completion.call(nil)
                } catch { completion.call(FileProviderErrorMapper.map(error)) }
                return
            }
            let registry = try? AppGroupStoreFactory().registryStore()
            do {
                guard let store = self.store else { throw CoreFailure(code: .database, retryable: false) }
                let scope = itemIdentifiers.first?.rawValue ?? NSFileProviderItemIdentifier.rootContainer.rawValue
                guard scope == NSFileProviderItemIdentifier.rootContainer.rawValue || scope == NSFileProviderItemIdentifier.workingSet.rawValue || CloudreveIdentifier.validate(scope, prefix: CloudreveIdentifier.itemPrefix) else { throw CoreFailure(code: .unsupportedMetadata, retryable: false) }
                guard let stored = try store.domain(identifier: self.domain.identifier.rawValue),
                      let remoteScope = try? RemoteScope(origin: stored.origin, accountID: stored.accountID, rootURI: stored.rootURI),
                      let origin = URL(string: stored.origin) else {
                    throw CoreFailure(code: .database, retryable: false)
                }
                var descriptor = DomainDescriptor(identifier: stored.identifier, displayName: stored.displayName, scope: remoteScope, rootRemoteID: stored.rootRemoteID, accountID: stored.accountID, secretReference: stored.secretReference, capabilitySnapshot: stored.capabilitySnapshot, iconURL: stored.iconURL)
                descriptor.status = .reconciling
                try store.setDomainStatus(identifier: stored.identifier, status: .reconciling)
                try? registry?.setDomainStatus(identifier: stored.identifier, status: .reconciling)
                reconciliationLogger.info("manual_reconcile.started domain=\(stored.identifier, privacy: .public) scope=\(scope, privacy: .public)")

                let vault = KeychainCredentialVault(accessGroup: KeychainAccessGroup.current())
                let reconciler = CloudreveReconciliationService(origin: origin, store: store, registry: registry, vault: vault, credentialReference: stored.secretReference)
                try await reconciler.reconcile(descriptor: descriptor, reason: "manual_check")

                let signaller = FileProviderWorkingSetSignaller(domain: self.domain)
                let drainer = SignalOutboxDrainer(store: store, signaller: signaller)
                guard await drainer.drain() else { throw CoreFailure(code: .network, retryable: true) }
                // A manual check must also wake Finder when the item was
                // already journaled but the previous system signal was missed.
                try await signaller.signalWorkingSet()
                let finalStatus: DomainStatus = try store.hasDirtyWork() ? .syncing : .healthy
                try store.setDomainStatus(identifier: stored.identifier, status: finalStatus)
                try? registry?.setDomainStatus(identifier: stored.identifier, status: finalStatus)
                reconciliationLogger.info("manual_reconcile.completed domain=\(stored.identifier, privacy: .public)")
                progress.completedUnitCount = 1
                completion.call(nil)
            } catch {
                if let store = self.store, let stored = try? store.domain(identifier: self.domain.identifier.rawValue) {
                    let status = fileProviderReconciliationStatus(for: error)
                    try? store.setDomainStatus(identifier: stored.identifier, status: status)
                    try? registry?.setDomainStatus(identifier: stored.identifier, status: status)
                    reconciliationLogger.error("manual_reconcile.failed domain=\(stored.identifier, privacy: .public) code=\(fileProviderErrorCode(error), privacy: .public)")
                } else {
                    reconciliationLogger.error("manual_reconcile.failed code=\(fileProviderErrorCode(error), privacy: .public)")
                }
                completion.call(FileProviderErrorMapper.map(error))
            }
        }
        progress.cancellationHandler = {
            task.cancel()
            completion.call(FileProviderErrorMapper.map(CoreFailure(code: .cancelled, retryable: false)))
        }
        return progress
    }

    private func evict(identifier: NSFileProviderItemIdentifier, manager: NSFileProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.evictItem(identifier: identifier) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func rootItem() -> NimbusSyncFileProviderItem {
        let authenticated = currentAuthenticationState() ?? false
        let storedRoot: StoredDomain?
        if let store { storedRoot = try? store.domain(identifier: domain.identifier.rawValue) } else { storedRoot = nil }
        let rootURI = storedRoot?.rootURI ?? "/"
        // The domain root itself is never renamed, moved or deleted (the
        // item projection strips those capabilities for the root), but users
        // must be able to create and drop items into it. The server still
        // enforces permissions on the scoped root folder.
        let rootWritable = authenticated && (storedRoot?.capabilitySnapshot.allowsCreate ?? false)
        let root = RemoteItem(itemIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: domain.displayName, uri: rootURI, kind: .folder, contentType: UTType.folder.identifier, version: ItemVersion(content: Data("root".utf8), metadata: Data(domain.identifier.rawValue.utf8)), canRead: authenticated, canWrite: rootWritable, canAddChildren: rootWritable, canTrash: false, canDelete: false)
        let childCount = try? store?.completeChildItemCount(parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue)
        let projection = ItemProjection(item: root, localState: ItemLocalState(), childItemCount: childCount ?? nil)
        return NimbusSyncFileProviderItem(projection: projection)
    }

    private func trashContainerItem() -> NimbusSyncFileProviderItem {
        let authenticated = currentAuthenticationState() ?? false
        let rootURI = (try? store?.domain(identifier: domain.identifier.rawValue))??.rootURI ?? "/"
        let trash = RemoteItem(itemIdentifier: NSFileProviderItemIdentifier.trashContainer.rawValue, parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "Trash", uri: rootURI, kind: .folder, contentType: UTType.folder.identifier, version: ItemVersion(content: Data("trash".utf8), metadata: Data(domain.identifier.rawValue.utf8)), canRead: authenticated, canWrite: false, canAddChildren: false, canTrash: false, canDelete: false)
        return NimbusSyncFileProviderItem(model: trash, authenticated: authenticated)
    }

    private func currentAuthenticationState() -> Bool? {
        if let store {
            do {
                guard let stored = try store.domain(identifier: domain.identifier.rawValue) else { return false }
                return stored.status != .authExpired
            } catch {
                return false
            }
        }
        stateLock.lock()
        defer { stateLock.unlock() }
        return stateProjection.userInfo["authenticated"] as? Bool
    }

    private func templateModel(_ template: NSFileProviderItem) throws -> RemoteItem {
        guard let type = template.contentType else { throw CoreFailure(code: .unsupportedMetadata, retryable: false) }
        let kind: RemoteItemKind = type.conforms(to: .symbolicLink) ? .symlink : (type.conforms(to: .folder) ? .folder : .file)
        let size = (template.documentSize as? NSNumber)?.int64Value ?? 0
        let parentIdentifier = template.parentItemIdentifier.rawValue
        let parentURI: String
        if parentIdentifier == NSFileProviderItemIdentifier.rootContainer.rawValue {
            parentURI = (try? store?.domain(identifier: domain.identifier.rawValue))??.rootURI ?? "/"
        } else {
            parentURI = (try? store?.item(identifier: parentIdentifier))??.uri ?? "/"
        }
        let uri = (try? CloudreveRemoteURI.append(parentURI, name: template.filename)) ?? "/\(template.filename)"
        return RemoteItem(itemIdentifier: CloudreveIdentifier.item(forTemplate: template.itemIdentifier.rawValue), parentIdentifier: parentIdentifier, name: template.filename, uri: uri, kind: kind, contentType: type.identifier, size: size, version: ItemVersion(content: Data(), metadata: Data()), canRead: true, canWrite: true, canAddChildren: kind == .folder, canTrash: true, canDelete: false)
    }

    /// Fields Cloudreve does not store are reported back as still pending.
    /// When that set equals the requested set the system treats the fields as
    /// unsupported and stops sending them, and it never overwrites the local
    /// values (e.g. a `touch`ed mtime) with the server's.
    private func unsupportedFields(_ fields: NSFileProviderItemFields) -> NSFileProviderItemFields {
        fields.subtracting(AsyncFileProviderMutationCoordinator.remoteModifyFields)
    }

    private func persistDomainState() {
        guard let url = AppGroupPaths.domainVersionURL(domain.identifier.rawValue) else { return }
        try? stateProjection.persist(to: url)
    }

    private func advanceDomainState() {
        stateLock.lock()
        stateProjection.advance()
        persistDomainState()
        stateLock.unlock()
    }
}

private final class ErrorCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void
    private let lock = NSLock()
    private var finished = false
    init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }
    func call(_ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        handler(error)
    }
}

private final class VoidCompletion: @unchecked Sendable {
    private let handler: () -> Void
    private let lock = NSLock()
    private var finished = false

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func call() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        handler()
    }
}

private final class ThumbnailCompletion: @unchecked Sendable {
    private let handler: (NSFileProviderItemIdentifier, Data?, Error?) -> Void
    init(_ handler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void) { self.handler = handler }
    func call(_ identifier: NSFileProviderItemIdentifier, _ data: Data?, _ error: Error?) { handler(identifier, data, error) }
}

private final class ItemCompletion: @unchecked Sendable {
    private let handler: (NSFileProviderItem?, Error?) -> Void
    private let lock = NSLock()
    private var finished = false

    init(_ handler: @escaping (NSFileProviderItem?, Error?) -> Void) { self.handler = handler }

    func call(_ item: NSFileProviderItem?, _ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        handler(item, error)
    }
}

private final class MutationCompletion: @unchecked Sendable {
    private let handler: (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    private let lock = NSLock()
    private var finished = false

    init(_ handler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) { self.handler = handler }

    func call(_ item: NSFileProviderItem?, _ fields: NSFileProviderItemFields, _ replaced: Bool, _ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        handler(item, fields, replaced, error)
    }
}

private final class DeleteCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void
    private let lock = NSLock()
    private var finished = false

    init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }

    func call(_ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        handler(error)
    }
}

private func makeThumbnail(data: Data, size: CGSize) -> Data? {
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: max(16, Int(max(size.width, size.height))), kCGImageSourceCreateThumbnailWithTransform: true]
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), let destinationData = CFDataCreateMutable(nil, 0), let destination = CGImageDestinationCreateWithData(destinationData, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return destinationData as Data
}

private func fileProviderErrorCode(_ error: Error) -> String {
    if let failure = error as? CoreFailure { return failure.code.rawValue }
    if error is CancellationError { return "cancelled" }
    let nsError = error as NSError
    return "error_\(nsError.domain)_\(nsError.code)"
}

private func fileProviderReconciliationStatus(for error: Error) -> DomainStatus {
    guard let failure = error as? CoreFailure else { return .eventDegraded }
    switch failure.code {
    case .authentication: return .authExpired
    case .rootUnavailable: return .rootUnavailable
    case .scopeConflict: return .scopeConflict
    case .database: return .repairRequired
    default: return .eventDegraded
    }
}

public enum FileProviderErrorMapper {
    /// Native macOS 26 conflict copies remain disabled until the signed
    /// Finder contract test proves the framework preserves both contents.
    /// Keeping this false also keeps the matching Info.plist declaration out
    /// of the release bundle.
    public static let nativeConflictSupportVerified = false

    public static func mapModifyError(_ error: Error, options: NSFileProviderModifyItemOptions) -> NSError {
        if nativeConflictSupportVerified, #available(macOS 26.0, *), options.contains(.failOnConflict) {
            return map(error, failOnConflict: true)
        }
        return map(error)
    }

    public static func map(_ error: Error, failOnConflict: Bool) -> NSError {
        if #available(macOS 26.0, *), failOnConflict, let failure = error as? CoreFailure, failure.code == .versionConflict {
            return NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.localVersionConflictingWithServer.rawValue, userInfo: ["correlationID": failure.correlationID.uuidString])
        }
        return map(error)
    }

    private static let logger = Logger(subsystem: "ai.tiy.nimbussync", category: "file-provider-error")

    /// Redacted, enum-only description of an error before it collapses into
    /// a File Provider code. Never includes messages, URIs, names or SQL.
    public static func diagnosticSummary(_ error: Error) -> String {
        if let failure = error as? CoreFailure {
            return "core:\(failure.code.rawValue) stage=\(failure.redactedContext["stage"] ?? "-")"
        }
        if let storeError = error as? StoreBridgeError {
            switch storeError {
            case .openFailed: return "store:open_failed"
            case .sql: return "store:sql:\(storeError.sqlCategory ?? "other")"
            case .schemaFenced: return "store:schema_fenced"
            case .anchorExpired: return "store:anchor_expired"
            case .pageTokenInvalid: return "store:page_token_invalid"
            case .snapshotExpired: return "store:snapshot_expired"
            case .generationFenced: return "store:generation_fenced"
            case .corrupted: return "store:corrupted"
            case .unknownDomain: return "store:unknown_domain"
            }
        }
        if let decoding = error as? DecodingError {
            let kind: String
            let context: DecodingError.Context?
            switch decoding {
            case .typeMismatch(_, let value): kind = "type_mismatch"; context = value
            case .valueNotFound(_, let value): kind = "value_not_found"; context = value
            case .keyNotFound(let key, let value): kind = "key_not_found:\(key.stringValue)"; context = value
            case .dataCorrupted(let value): kind = "data_corrupted"; context = value
            @unknown default: kind = "unknown"; context = nil
            }
            let path = context?.codingPath.map { key in key.intValue.map { "[\($0)]" } ?? key.stringValue }.joined(separator: ".") ?? ""
            return "decoding:\(kind) path=\(path)"
        }
        if let urlError = error as? URLError { return "url:\(urlError.code.rawValue)" }
        if error is AnchorValidationError { return "anchor_validation" }
        let nsError = error as NSError
        return "\(String(describing: type(of: error))):\(nsError.domain):\(nsError.code)"
    }

    public static func map(_ error: Error) -> NSError {
        let mapped = mapWithoutLogging(error)
        if mapped.domain == NSFileProviderErrorDomain, (error as NSError).domain != NSFileProviderErrorDomain {
            let correlation = (mapped.userInfo["correlationID"] as? String) ?? "-"
            if isDeletionAnswer(error) {
                // Not a failure: the extension itself decided the item is deleted (and told the
                // working set). Whoever decided it already logged why, with the item.
                logger.notice("fp.error.mapped fp_code=\(mapped.code, privacy: .public) source=\(diagnosticSummary(error), privacy: .public) correlationID=\(correlation, privacy: .public)")
                return mapped
            }
            logger.error("fp.error.mapped fp_code=\(mapped.code, privacy: .public) source=\(diagnosticSummary(error), privacy: .public) correlationID=\(correlation, privacy: .public)")
            if mapped.code == NSFileProviderError.syncAnchorExpired.rawValue, isExpectedAnchorExpiry(error) {
                // Expected after the sync epoch rotates (the server folder moved, or the journal
                // was compacted past Finder's position): the system re-reads the Domain.
                // A malformed, tampered or unsupported anchor also maps to syncAnchorExpired but
                // is not expected, so it stays an error.
                ActivityLog.shared.info("file-provider", "Finder's sync position expired; re-reading the domain · \(diagnosticSummary(error))")
            } else {
                ActivityLog.shared.error("file-provider", "File Provider error \(mapped.code) · \(diagnosticSummary(error))")
            }
        }
        return mapped
    }

    /// noSuchItem answers for items the extension deleted on purpose: one it no longer serves
    /// (`deleted_item`) or one whose path is empty or holds another object, which was deleted
    /// locally instead of acted on. They report a decision, not a failure.
    static func isDeletionAnswer(_ error: Error) -> Bool {
        guard let failure = error as? CoreFailure else { return false }
        return failure.isRemoteObjectGone || failure.isDeletedItemAnswer
    }

    private static func isExpectedAnchorExpiry(_ error: Error) -> Bool {
        (error as? AnchorValidationError) == .expired || (error as? StoreBridgeError) == .anchorExpired
    }

    private static func mapWithoutLogging(_ error: Error) -> NSError {
        let nsError = error as NSError
        if nsError.domain == NSFileProviderErrorDomain || nsError.domain == NSCocoaErrorDomain { return nsError }
        let code: Int
        let context: [String: Any]
        if let failure = error as? CoreFailure {
            switch failure.code {
            case .authentication: code = NSFileProviderError.notAuthenticated.rawValue
            case .network: code = NSFileProviderError.serverUnreachable.rawValue
            case .notFound: code = NSFileProviderError.noSuchItem.rawValue
            case .quotaExceeded: code = NSFileProviderError.insufficientQuota.rawValue
            case .versionConflict: code = NSFileProviderError.cannotSynchronize.rawValue
            case .nameCollision: code = NSFileProviderError.filenameCollision.rawValue
            case .directoryNotEmpty: code = NSFileProviderError.directoryNotEmpty.rawValue
            case .cancelled: return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
            case .excludedFromSync: code = NSFileProviderError.excludedFromSync.rawValue
            default: code = NSFileProviderError.cannotSynchronize.rawValue
            }
            context = ["correlationID": failure.correlationID.uuidString]
        } else if let anchorError = error as? AnchorValidationError {
            switch anchorError {
            case .expired, .checksumMismatch, .unsupportedVersion, .malformed:
                code = NSFileProviderError.syncAnchorExpired.rawValue
            }
            context = ["reason": "anchor_validation"]
        } else if let storeError = error as? StoreBridgeError, storeError == .schemaFenced {
            code = NSFileProviderError.cannotSynchronize.rawValue; context = ["reason": "schema_fenced"]
        } else if let storeError = error as? StoreBridgeError {
            switch storeError {
            case .anchorExpired:
                code = NSFileProviderError.syncAnchorExpired.rawValue
                context = ["reason": "anchor_expired"]
            case .pageTokenInvalid, .snapshotExpired:
                // pageExpired makes the system restart the enumeration from
                // the initial page; cannotSynchronize only backs off and
                // retries the same dead token.
                code = NSFileProviderError.pageExpired.rawValue
                context = ["reason": "page_snapshot_invalid"]
            case .generationFenced:
                code = NSFileProviderError.cannotSynchronize.rawValue
                context = ["reason": "generation_fenced"]
            default:
                code = NSFileProviderError.cannotSynchronize.rawValue
                context = [:]
            }
        } else { code = NSFileProviderError.cannotSynchronize.rawValue; context = [:] }
        return NSError(domain: NSFileProviderErrorDomain, code: code, userInfo: context)
    }
}
