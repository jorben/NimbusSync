import Foundation
import FileProvider
import CryptoKit
import CloudreveDomainKit
import CloudreveStoreBridge

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledValue = false
    private var handlers: [() -> Void] = []

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledValue
    }

    public func cancel() {
        lock.lock()
        guard !cancelledValue else {
            lock.unlock()
            return
        }
        cancelledValue = true
        let handlers = self.handlers
        self.handlers.removeAll()
        lock.unlock()
        handlers.forEach { $0() }
    }

    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancelledValue {
            lock.unlock()
            handler()
            return
        }
        handlers.append(handler)
        lock.unlock()
    }

    public func throwIfCancelled() throws {
        if isCancelled || Task.isCancelled {
            throw CoreFailure(code: .cancelled, retryable: false)
        }
    }
}

public protocol URLSessionTaskRegistrar: Sendable {
    func registerSuspended(_ task: URLSessionTask, for itemIdentifier: NSFileProviderItemIdentifier) async throws
}

public struct FileProviderOperationContext: @unchecked Sendable {
    public let itemIdentifier: NSFileProviderItemIdentifier
    public let progress: Progress
    public let registrar: any URLSessionTaskRegistrar
    public let cancellation: CancellationToken

    public init(itemIdentifier: NSFileProviderItemIdentifier, progress: Progress, registrar: any URLSessionTaskRegistrar, cancellation: CancellationToken) {
        self.itemIdentifier = itemIdentifier
        self.progress = progress
        self.registrar = registrar
        self.cancellation = cancellation
    }
}

public struct PageCursor: Codable, Equatable, Sendable {
    public let generation: UInt64
    public let lastItemIdentifier: String?
    public let opaqueCursor: Data?
    public let snapshotID: String?
    public let expiresAt: Int64?

    public init(generation: UInt64 = 0, lastItemIdentifier: String? = nil, opaqueCursor: Data? = nil, snapshotID: String? = nil, expiresAt: Int64? = nil) {
        self.generation = generation
        self.lastItemIdentifier = lastItemIdentifier
        self.opaqueCursor = opaqueCursor
        self.snapshotID = snapshotID
        self.expiresAt = expiresAt
    }
}

public struct RemotePage: Equatable, Sendable {
    public let items: [RemoteItem]
    public let nextCursor: PageCursor?
    public let complete: Bool
    public let snapshotID: String?
    public let expiresAt: Int64?

    public init(items: [RemoteItem], nextCursor: PageCursor?, complete: Bool, snapshotID: String? = nil, expiresAt: Int64? = nil) {
        self.items = items
        self.nextCursor = nextCursor
        self.complete = complete
        self.snapshotID = snapshotID
        self.expiresAt = expiresAt
    }
}

public struct CreateRequest: @unchecked Sendable {
    public let template: RemoteItem
    public let contents: URL?
    public let replayKey: String
    public init(template: RemoteItem, contents: URL?, replayKey: String) {
        self.template = template
        self.contents = contents
        self.replayKey = replayKey
    }
}

public struct ModifyRequest: @unchecked Sendable {
    public let item: RemoteItem
    public let expectedVersion: Data?
    public let changedFields: NSFileProviderItemFields
    public let contents: URL?
    public let options: NSFileProviderModifyItemOptions
    public let replayKey: String
    public init(item: RemoteItem, expectedVersion: Data?, changedFields: NSFileProviderItemFields, contents: URL?, options: NSFileProviderModifyItemOptions, replayKey: String) {
        self.item = item
        self.expectedVersion = expectedVersion
        self.changedFields = changedFields
        self.contents = contents
        self.options = options
        self.replayKey = replayKey
    }
}

public struct TrashRequest: Sendable {
    public let item: RemoteItem
    public let expectedVersion: Data?
    public let replayKey: String
    public init(item: RemoteItem, expectedVersion: Data?, replayKey: String) {
        self.item = item
        self.expectedVersion = expectedVersion
        self.replayKey = replayKey
    }
}

public struct RestoreRequest: Sendable {
    public let item: RemoteItem
    public let expectedVersion: Data?
    public let replayKey: String
    public init(item: RemoteItem, expectedVersion: Data?, replayKey: String) {
        self.item = item
        self.expectedVersion = expectedVersion
        self.replayKey = replayKey
    }
}

public struct DeleteRequest: Sendable {
    public let itemIdentifier: String
    public let expectedVersion: Data?
    public let recursive: Bool
    public let replayKey: String
    public init(itemIdentifier: String, expectedVersion: Data?, recursive: Bool, replayKey: String) {
        self.itemIdentifier = itemIdentifier
        self.expectedVersion = expectedVersion
        self.recursive = recursive
        self.replayKey = replayKey
    }
}

public protocol CloudreveAsyncBackend: Sendable {
    func item(identifier: String) async throws -> RemoteItem?
    func childrenPage(parentIdentifier: String, cursor: PageCursor?) async throws -> RemotePage
    func childrenPage(parentIdentifier: String, cursor: PageCursor?, context: FileProviderOperationContext) async throws -> RemotePage
    func trashItems() async throws -> [RemoteItem]
    /// Enumeration-side network work uses the same suspended/register/resume
    /// contract as mutations. The no-context overload remains for test and
    /// local adapters.
    func trashItems(context: FileProviderOperationContext) async throws -> [RemoteItem]
    func fetchContent(identifier: String, expectedVersion: Data?, destination: URL, context: FileProviderOperationContext) async throws -> RemoteItem
    func create(_ request: CreateRequest, context: FileProviderOperationContext) async throws -> RemoteItem
    func modify(_ request: ModifyRequest, context: FileProviderOperationContext) async throws -> RemoteItem
    func trash(_ request: TrashRequest, context: FileProviderOperationContext) async throws -> RemoteItem
    func restore(_ request: RestoreRequest, context: FileProviderOperationContext) async throws -> RemoteItem
    func delete(_ request: DeleteRequest, context: FileProviderOperationContext) async throws
    /// Reads the current server state of an item (not the local cache).
    func refreshItem(identifier: String, context: FileProviderOperationContext) async throws -> RemoteItem?
    /// Server-generated thumbnail. `.unsupported` makes the caller fall back
    /// to rendering from file contents.
    func thumbnail(identifier: String, context: FileProviderOperationContext) async throws -> ThumbnailFetchResult
}

public enum ThumbnailFetchResult: Sendable, Equatable {
    case image(Data)
    case unavailable
    case unsupported
}

public extension CloudreveAsyncBackend {
    func thumbnail(identifier: String, context: FileProviderOperationContext) async throws -> ThumbnailFetchResult { .unsupported }

    func refreshItem(identifier: String, context: FileProviderOperationContext) async throws -> RemoteItem? {
        try await item(identifier: identifier)
    }

    func childrenPage(parentIdentifier: String, cursor: PageCursor?, context: FileProviderOperationContext) async throws -> RemotePage {
        try await childrenPage(parentIdentifier: parentIdentifier, cursor: cursor)
    }

    func trashItems() async throws -> [RemoteItem] {
        throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true)
    }

    func trashItems(context: FileProviderOperationContext) async throws -> [RemoteItem] {
        try await trashItems()
    }
}

public final class FileProviderManagerTaskRegistrar: URLSessionTaskRegistrar, @unchecked Sendable {
    private let manager: NSFileProviderManager
    public init(manager: NSFileProviderManager) {
        self.manager = manager
    }

    public func registerSuspended(_ task: URLSessionTask, for itemIdentifier: NSFileProviderItemIdentifier) async throws {
        guard task.state == .suspended else {
            throw CoreFailure(code: .cannotSynchronize, retryable: false, userActionRequired: true, redactedContext: ["stage": "task_not_suspended"])
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.register(task, forItemWithIdentifier: itemIdentifier) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

public struct NoopURLSessionTaskRegistrar: URLSessionTaskRegistrar, Sendable {
    public init() {}
    public func registerSuspended(_ task: URLSessionTask, for itemIdentifier: NSFileProviderItemIdentifier) async throws {
        guard task.state == .suspended else {
            throw CoreFailure(code: .cannotSynchronize, retryable: false, userActionRequired: true, redactedContext: ["stage": "task_not_suspended"])
        }
    }
}

private final class RegisteredTaskGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resolve(_ result: sending Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// File Provider associates registered URLSession tasks with an item. Keep a
/// process-local admission gate as well so a retry cannot accidentally leave
/// two active uploads/downloads for the same item. The system manager remains
/// the cross-process authority.
extension CoreFailure {
    /// The limiter turned the request away because the same item already has one in flight.
    /// That request answers the caller too, so this one is not a failure the user should see.
    public var isAlreadyRegisteredTransfer: Bool {
        code == .cannotSynchronize && redactedContext["stage"] == "task_already_registered"
    }

    /// The server holds a different object at the item's path: the one the item stood for was
    /// deleted or replaced, so the item is stale for good and asking again cannot help.
    public var isRemoteIdentityChanged: Bool {
        code == .notFound && redactedContext["stage"] == "remote_identity_changed"
    }

    /// Nothing is at the item's path on the server any more (deleted, or moved where the item no
    /// longer points).
    public var isRemotePathEmpty: Bool {
        code == .notFound && redactedContext["stage"] == "remote_path_empty"
    }

    /// What the item stood for is no longer at its path, so acting on the path cannot help: the
    /// item is deleted locally instead.
    public var isRemoteObjectGone: Bool { isRemoteIdentityChanged || isRemotePathEmpty }
}

private final class RegisteredTaskLimiter: @unchecked Sendable {
    static let shared = RegisteredTaskLimiter()
    private let lock = NSLock()
    private var activeItems = Set<String>()

    func acquire(itemIdentifier: NSFileProviderItemIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeItems.insert(itemIdentifier.rawValue).inserted
    }

    func release(itemIdentifier: NSFileProviderItemIdentifier) {
        lock.lock()
        activeItems.remove(itemIdentifier.rawValue)
        lock.unlock()
    }
}

/// Creates a suspended task, waits for File Provider registration, and only
/// then resumes it. The response body is held only for small API responses;
/// content downloads use the download-to-file path below.
public final class RegisteredURLSessionTransport: @unchecked Sendable {
    private let session: URLSession
    fileprivate var sessionForStreaming: URLSession { session }

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest, itemIdentifier: NSFileProviderItemIdentifier, context: FileProviderOperationContext) async throws -> (Data, HTTPURLResponse) {
        try context.cancellation.throwIfCancelled()
        guard RegisteredTaskLimiter.shared.acquire(itemIdentifier: itemIdentifier) else {
            throw CoreFailure(code: .cannotSynchronize, retryable: true, userActionRequired: true, redactedContext: ["stage": "task_already_registered"])
        }
        defer { RegisteredTaskLimiter.shared.release(itemIdentifier: itemIdentifier) }
        let gate = RegisteredTaskGate<(Data, HTTPURLResponse)>()
        let task = session.dataTask(with: request) { data, response, error in
            if let error { gate.resolve(.failure(error)); return }
            guard let response = response as? HTTPURLResponse else {
                gate.resolve(.failure(CoreFailure(code: .network, retryable: true)))
                return
            }
            gate.resolve(.success((data ?? Data(), response)))
        }
        context.progress.addChild(task.progress, withPendingUnitCount: 1)
        context.cancellation.onCancel { task.cancel() }
        return try await withTaskCancellationHandler(operation: {
            do {
                try await context.registrar.registerSuspended(task, for: itemIdentifier)
                try context.cancellation.throwIfCancelled()
                task.resume()
            } catch {
                task.cancel()
                gate.resolve(.failure(error))
            }
            return try await gate.wait()
        }, onCancel: {
            context.cancellation.cancel()
            task.cancel()
            gate.resolve(.failure(CoreFailure(code: .cancelled, retryable: false)))
        })
    }

    public func download(to destination: URL, request: URLRequest, itemIdentifier: NSFileProviderItemIdentifier, context: FileProviderOperationContext) async throws -> HTTPURLResponse {
        try context.cancellation.throwIfCancelled()
        guard RegisteredTaskLimiter.shared.acquire(itemIdentifier: itemIdentifier) else {
            throw CoreFailure(code: .cannotSynchronize, retryable: true, userActionRequired: true, redactedContext: ["stage": "task_already_registered"])
        }
        defer { RegisteredTaskLimiter.shared.release(itemIdentifier: itemIdentifier) }
        let gate = RegisteredTaskGate<(URL, HTTPURLResponse)>()
        let task = session.downloadTask(with: request) { url, response, error in
            if let error { gate.resolve(.failure(error)); return }
            guard let url, let response = response as? HTTPURLResponse else {
                gate.resolve(.failure(CoreFailure(code: .network, retryable: true)))
                return
            }
            gate.resolve(.success((url, response)))
        }
        context.progress.addChild(task.progress, withPendingUnitCount: 1)
        context.cancellation.onCancel { task.cancel() }
        let (temporaryURL, response) = try await withTaskCancellationHandler(operation: {
            do {
                try await context.registrar.registerSuspended(task, for: itemIdentifier)
                try context.cancellation.throwIfCancelled()
                task.resume()
            } catch {
                task.cancel()
                gate.resolve(.failure(error))
            }
            return try await gate.wait()
        }, onCancel: {
            context.cancellation.cancel()
            task.cancel()
            gate.resolve(.failure(CoreFailure(code: .cancelled, retryable: false)))
        })
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try context.cancellation.throwIfCancelled()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return response
    }

    public func uploadFile(from source: URL, request: URLRequest, itemIdentifier: NSFileProviderItemIdentifier, context: FileProviderOperationContext) async throws -> HTTPURLResponse {
        try context.cancellation.throwIfCancelled()
        guard RegisteredTaskLimiter.shared.acquire(itemIdentifier: itemIdentifier) else {
            throw CoreFailure(code: .cannotSynchronize, retryable: true, userActionRequired: true, redactedContext: ["stage": "task_already_registered"])
        }
        defer { RegisteredTaskLimiter.shared.release(itemIdentifier: itemIdentifier) }
        let gate = RegisteredTaskGate<HTTPURLResponse>()
        let task = session.uploadTask(with: request, fromFile: source) { _, response, error in
            if let error { gate.resolve(.failure(error)); return }
            guard let response = response as? HTTPURLResponse else {
                gate.resolve(.failure(CoreFailure(code: .network, retryable: true)))
                return
            }
            gate.resolve(.success(response))
        }
        context.progress.addChild(task.progress, withPendingUnitCount: 1)
        context.cancellation.onCancel { task.cancel() }
        return try await withTaskCancellationHandler(operation: {
            do {
                try await context.registrar.registerSuspended(task, for: itemIdentifier)
                try context.cancellation.throwIfCancelled()
                task.resume()
            } catch {
                task.cancel()
                gate.resolve(.failure(error))
            }
            return try await gate.wait()
        }, onCancel: {
            context.cancellation.cancel()
            task.cancel()
            gate.resolve(.failure(CoreFailure(code: .cancelled, retryable: false)))
        })
    }
}

/// Streams a registered data task into a partial file so an interrupted
/// transfer keeps every byte already received. A completion-handler download
/// task discards its temporary file on failure, which made large downloads
/// restart from zero on every retry.
extension RegisteredURLSessionTransport {
    public func streamDownload(appendingTo partialURL: URL, resumeOffset: Int64, request: URLRequest, itemIdentifier: NSFileProviderItemIdentifier, context: FileProviderOperationContext) async throws -> HTTPURLResponse {
        try context.cancellation.throwIfCancelled()
        guard RegisteredTaskLimiter.shared.acquire(itemIdentifier: itemIdentifier) else {
            throw CoreFailure(code: .cannotSynchronize, retryable: true, userActionRequired: true, redactedContext: ["stage": "task_already_registered"])
        }
        defer { RegisteredTaskLimiter.shared.release(itemIdentifier: itemIdentifier) }
        let gate = RegisteredTaskGate<HTTPURLResponse>()
        let delegate = StreamingDownloadDelegate(fileURL: partialURL, resumeOffset: resumeOffset, gate: gate)
        let task = sessionForStreaming.dataTask(with: request)
        task.delegate = delegate
        context.progress.addChild(task.progress, withPendingUnitCount: 1)
        context.cancellation.onCancel { task.cancel() }
        return try await withTaskCancellationHandler(operation: {
            do {
                try await context.registrar.registerSuspended(task, for: itemIdentifier)
                try context.cancellation.throwIfCancelled()
                task.resume()
            } catch {
                task.cancel()
                gate.resolve(.failure(error))
            }
            return try await gate.wait()
        }, onCancel: {
            context.cancellation.cancel()
            task.cancel()
            gate.resolve(.failure(CoreFailure(code: .cancelled, retryable: false)))
        })
    }
}

private final class StreamingDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let fileURL: URL
    private let resumeOffset: Int64
    private let gate: RegisteredTaskGate<HTTPURLResponse>
    private let lock = NSLock()
    private var handle: FileHandle?
    private var response: HTTPURLResponse?
    private var failure: Error?
    private var discardedNonSuccess = false

    init(fileURL: URL, resumeOffset: Int64, gate: RegisteredTaskGate<HTTPURLResponse>) {
        self.fileURL = fileURL
        self.resumeOffset = resumeOffset
        self.gate = gate
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard let http = response as? HTTPURLResponse else {
            failure = CoreFailure(code: .network, retryable: true)
            completionHandler(.cancel)
            return
        }
        self.response = http
        do {
            switch http.statusCode {
            case 206 where resumeOffset > 0 && Self.contentRangeStart(http) == resumeOffset:
                let output = try FileHandle(forWritingTo: fileURL)
                try output.seekToEnd()
                handle = output
                completionHandler(.allow)
            case 200:
                // The server ignored the range (or none was sent): restart.
                guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                    throw CoreFailure(code: .network, retryable: true)
                }
                handle = try FileHandle(forWritingTo: fileURL)
                completionHandler(.allow)
            case 206:
                // A range we did not ask for cannot be appended safely.
                try? FileManager.default.removeItem(at: fileURL)
                failure = CoreFailure(code: .integrityFailure, retryable: true, redactedContext: ["stage": "content_range_mismatch"])
                completionHandler(.cancel)
            default:
                // Error status: keep the partial file, report the status.
                discardedNonSuccess = true
                completionHandler(.cancel)
            }
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil, let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        let response = self.response
        let failure = self.failure
        let discardedNonSuccess = self.discardedNonSuccess
        lock.unlock()
        if let failure {
            gate.resolve(.failure(failure))
        } else if discardedNonSuccess, let response {
            gate.resolve(.success(response))
        } else if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                gate.resolve(.failure(CoreFailure(code: .cancelled, retryable: false)))
            } else {
                gate.resolve(.failure(CoreFailure(code: .network, retryable: true, redactedContext: ["error": "url_session"])))
            }
        } else if let response {
            gate.resolve(.success(response))
        } else {
            gate.resolve(.failure(CoreFailure(code: .network, retryable: true)))
        }
    }

    /// Parses the first byte offset of `Content-Range: bytes <start>-<end>/<total>`.
    static func contentRangeStart(_ response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range")?.trimmingCharacters(in: .whitespaces).lowercased(),
              value.hasPrefix("bytes ") else { return nil }
        let range = value.dropFirst("bytes ".count)
        guard let dash = range.firstIndex(of: "-") else { return nil }
        return Int64(range[range.startIndex..<dash])
    }
}

/// Version-keyed partial downloads kept in the extension's own (sandboxed)
/// caches directory. The key covers the content version, so a remote change
/// can never be resumed on top of stale bytes.
public enum PartialDownloadStore {
    static let staleAfter: TimeInterval = 7 * 24 * 3_600

    public static func url(itemIdentifier: String, contentVersion: Data, fileManager: FileManager = .default) -> URL? {
        guard let directory = directory(fileManager: fileManager) else { return nil }
        let key = VersionHasher.digest([Data(itemIdentifier.utf8), contentVersion]).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(key).partial")
    }

    public static func size(of url: URL, fileManager: FileManager = .default) -> Int64 {
        ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    public static func purgeStale(now: Date = Date(), fileManager: FileManager = .default) {
        guard let directory = directory(fileManager: fileManager),
              let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > staleAfter { try? fileManager.removeItem(at: entry) }
        }
    }

    private static func directory(fileManager: FileManager) -> URL? {
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent("NimbusSyncPartialDownloads", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return directory
        } catch {
            return nil
        }
    }
}

/// Adapter used by unit tests and by deliberately read-only fallback paths.
/// Production callbacks use a native CloudreveAsyncBackend implementation.
public final class LegacyAsyncFileProviderBackendAdapter: CloudreveAsyncBackend, @unchecked Sendable {
    private let backend: FileProviderBackend
    public init(backend: FileProviderBackend) {
        self.backend = backend
    }

    public func item(identifier: String) async throws -> RemoteItem? {
        try await Task.detached(priority: .userInitiated) { try self.backend.item(identifier: identifier) }.value
    }

    public func childrenPage(parentIdentifier: String, cursor: PageCursor?) async throws -> RemotePage {
        let offset = cursor?.opaqueCursor.flatMap { Int(String(data: $0, encoding: .utf8) ?? "") } ?? 0
        let page: DirectoryPage
        if let snapshotID = cursor?.snapshotID,
           let snapshotBackend = backend as? any SnapshotAwareFileProviderBackend {
            page = try await Task.detached(priority: .userInitiated) {
                try snapshotBackend.childrenPage(parentIdentifier: parentIdentifier, offset: offset, limit: 200, snapshotID: snapshotID, generation: cursor?.generation ?? 0)
            }.value
        } else {
            page = try await Task.detached(priority: .userInitiated) {
                try self.backend.childrenPage(parentIdentifier: parentIdentifier, offset: offset, limit: 200)
            }.value
        }
        let next = page.nextOffset.map {
            PageCursor(
                generation: page.generation,
                opaqueCursor: Data(String($0).utf8),
                snapshotID: page.snapshotID ?? cursor?.snapshotID,
                expiresAt: page.expiresAt.map { Int64($0.timeIntervalSince1970) } ?? cursor?.expiresAt
            )
        }
        return RemotePage(items: page.items, nextCursor: next, complete: page.complete, snapshotID: page.snapshotID, expiresAt: page.expiresAt.map { Int64($0.timeIntervalSince1970) })
    }

    public func childrenPage(parentIdentifier: String, cursor: PageCursor?, context: FileProviderOperationContext) async throws -> RemotePage {
        try context.cancellation.throwIfCancelled()
        let page = try await childrenPage(parentIdentifier: parentIdentifier, cursor: cursor)
        try context.cancellation.throwIfCancelled()
        return page
    }

    public func trashItems() async throws -> [RemoteItem] {
        try await Task.detached(priority: .userInitiated) { try self.backend.trashItems() }.value
    }

    public func trashItems(context: FileProviderOperationContext) async throws -> [RemoteItem] {
        try context.cancellation.throwIfCancelled()
        let items = try await trashItems()
        try context.cancellation.throwIfCancelled()
        return items
    }

    public func fetchContent(identifier: String, expectedVersion: Data?, destination: URL, context: FileProviderOperationContext) async throws -> RemoteItem {
        try context.cancellation.throwIfCancelled()
        let item = try await Task.detached(priority: .userInitiated) { try self.backend.fetchContent(identifier: identifier, expectedVersion: expectedVersion, to: destination) }.value
        try context.cancellation.throwIfCancelled()
        return item
    }

    public func create(_ request: CreateRequest, context: FileProviderOperationContext) async throws -> RemoteItem {
        let content = try request.contents.map { try Data(contentsOf: $0, options: .mappedIfSafe) }
        return try await Task.detached(priority: .userInitiated) { try self.backend.create(template: request.template, content: content, replayKey: request.replayKey) }.value
    }

    public func modify(_ request: ModifyRequest, context: FileProviderOperationContext) async throws -> RemoteItem {
        let content = try request.contents.map { try Data(contentsOf: $0, options: .mappedIfSafe) }
        return try await Task.detached(priority: .userInitiated) { try self.backend.modify(item: request.item, expectedVersion: request.expectedVersion, changedFields: request.changedFields, content: content, replayKey: request.replayKey) }.value
    }

    public func trash(_ request: TrashRequest, context: FileProviderOperationContext) async throws -> RemoteItem {
        try await Task.detached(priority: .userInitiated) { try self.backend.trash(item: request.item, expectedVersion: request.expectedVersion, replayKey: request.replayKey) }.value
    }

    public func restore(_ request: RestoreRequest, context: FileProviderOperationContext) async throws -> RemoteItem {
        try await Task.detached(priority: .userInitiated) { try self.backend.restore(item: request.item, expectedVersion: request.expectedVersion, replayKey: request.replayKey) }.value
    }

    public func delete(_ request: DeleteRequest, context: FileProviderOperationContext) async throws {
        try await Task.detached(priority: .userInitiated) { try self.backend.delete(identifier: request.itemIdentifier, expectedVersion: request.expectedVersion, recursive: request.recursive) }.value
    }
}

public enum FileProviderSourceFingerprint {
    private static let cache = FingerprintCache()

    /// The coordinator (replay key) and the backend (upload session) both
    /// need the whole-file hash of the same callback source. Cache it by file
    /// identity so a multi-GB upload is hashed once, not once per layer.
    public static func digest(url: URL) throws -> (hash: Data, size: Int64) {
        guard let key = FingerprintCache.key(for: url) else { return try computeDigest(url: url) }
        if let cached = cache.value(for: key) { return cached }
        let result = try computeDigest(url: url)
        cache.store(result, for: key)
        return result
    }

    private static func computeDigest(url: URL) throws -> (hash: Data, size: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }
        return (Data(hasher.finalize()), size)
    }
}

private final class FingerprintCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (hash: Data, size: Int64)] = [:]
    private var order: [String] = []
    private let capacity = 32

    static func key(for url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return "\(url.path)|\(info.st_dev)|\(info.st_ino)|\(info.st_size)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)|\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
    }

    func value(for key: String) -> (hash: Data, size: Int64)? {
        lock.lock(); defer { lock.unlock() }
        return entries[key]
    }

    func store(_ value: (hash: Data, size: Int64), for key: String) {
        lock.lock(); defer { lock.unlock() }
        if entries[key] == nil { order.append(key) }
        entries[key] = value
        while order.count > capacity { entries.removeValue(forKey: order.removeFirst()) }
    }
}

public enum ConflictLocalSource: Codable, Equatable, Sendable {
    case systemPending(itemIdentifier: String, sourceGeneration: UInt64, expectedBaseVersion: Data, expectedHash: Data, expectedSize: Int64)
    case userExport(sourceGeneration: UInt64, expectedHash: Data, expectedSize: Int64)
    case unavailable
}

public enum ConflictSourceValidator {
    public static func validateData(_ data: Data, source: ConflictLocalSource) -> Bool {
        let digest = Data(SHA256.hash(data: data))
        switch source {
        case .systemPending(_, _, _, let expectedHash, let expectedSize), .userExport(_, let expectedHash, let expectedSize):
            return digest == expectedHash && Int64(data.count) == expectedSize
        case .unavailable:
            return false
        }
    }

    public static func validate(_ source: ConflictLocalSource, url: URL, itemIdentifier: String? = nil, sourceGeneration: UInt64? = nil) throws -> Bool {
        switch source {
        case let .systemPending(expectedIdentifier, expectedGeneration, _, expectedHash, expectedSize):
            guard itemIdentifier == expectedIdentifier, sourceGeneration == expectedGeneration else { return false }
            let result = try FileProviderSourceFingerprint.digest(url: url)
            return result.hash == expectedHash && result.size == expectedSize
        case let .userExport(expectedGeneration, expectedHash, expectedSize):
            if let sourceGeneration, sourceGeneration != expectedGeneration { return false }
            let result = try FileProviderSourceFingerprint.digest(url: url)
            return result.hash == expectedHash && result.size == expectedSize
        case .unavailable:
            return false
        }
    }
}
