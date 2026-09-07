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
}

public extension CloudreveAsyncBackend {
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
    public static func digest(url: URL) throws -> (hash: Data, size: Int64) {
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
