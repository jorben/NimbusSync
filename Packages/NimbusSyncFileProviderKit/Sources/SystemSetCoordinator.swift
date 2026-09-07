import Foundation
import FileProvider
import Darwin
import CloudreveDomainKit
import CloudreveStoreBridge

public struct SystemSetCollection: Equatable, Sendable {
    public let itemIdentifiers: [String]
    public let payloads: [String: Data]
    public let complete: Bool
    public let nextPage: Data?
    public let maximumSizeReached: Bool

    public init(itemIdentifiers: [String], payloads: [String: Data] = [:], complete: Bool, nextPage: Data? = nil, maximumSizeReached: Bool = false) {
        self.itemIdentifiers = itemIdentifiers
        self.payloads = payloads
        self.complete = complete
        self.nextPage = nextPage
        self.maximumSizeReached = maximumSizeReached
    }
}

private final class POSIXAdvisoryLock: @unchecked Sendable {
    private let descriptor: Int32

    init?(url: URL) {
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        self.descriptor = descriptor
    }

    deinit {
        _ = Darwin.lockf(descriptor, F_ULOCK, 0)
        Darwin.close(descriptor)
    }
}

private final class SystemSetContinuationGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: sending Value) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }

    func fail(_ error: Error) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(throwing: error)
    }
}

private final class SystemSetEnumerationCollector: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    private var enumerator: NSFileProviderEnumerator?
    private var gate: SystemSetContinuationGate<SystemSetCollection>?
    private var identifiers: [String] = []
    private var identifierSet = Set<String>()
    private var payloads: [String: Data] = [:]
    private var pageCount = 0
    private var maxPages = 4
    private let lock = NSLock()

    func collect(enumerator: NSFileProviderEnumerator, startingAt page: NSFileProviderPage, maxPages: Int = 4) async throws -> SystemSetCollection {
        try await withCheckedThrowingContinuation { continuation in
            let gate = SystemSetContinuationGate(continuation)
            lock.lock()
            self.enumerator = enumerator
            self.gate = gate
            self.maxPages = max(1, maxPages)
            lock.unlock()
            enumerator.enumerateItems(for: self, startingAt: page)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let gate = self.gate
                let enumerator = self.enumerator
                self.lock.unlock()
                gate?.fail(CoreFailure(code: .network, retryable: true, redactedContext: ["stage": "system_set_timeout"]))
                enumerator?.invalidate()
            }
        }
    }

    func didEnumerate(_ updatedItems: [NSFileProviderItem]) {
        lock.lock()
        pageCount += 1
        for item in updatedItems {
            let identifier = item.itemIdentifier.rawValue
            if identifierSet.insert(identifier).inserted {
                identifiers.append(identifier)
            }
            var values: [String: String] = [:]
            if let nsError = item.uploadingError as? NSError {
                values["uploadError"] = "\(nsError.domain):\(nsError.code)"
            }
            if let nsError = item.downloadingError as? NSError {
                values["downloadError"] = "\(nsError.domain):\(nsError.code)"
            }
            if !values.isEmpty, let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) {
                payloads[identifier] = data
            }
        }
        lock.unlock()
    }

    func finishEnumerating(upTo page: NSFileProviderPage?) {
        guard let page else {
            lock.lock()
            let result = SystemSetCollection(itemIdentifiers: identifiers, payloads: payloads, complete: true)
            lock.unlock()
            gate?.succeed(result)
            return
        }

        lock.lock()
        let shouldStop = pageCount >= maxPages
        let nextPage = Data(page as NSData)
        let nextEnumerator = enumerator
        lock.unlock()
        if shouldStop {
            gate?.succeed(SystemSetCollection(itemIdentifiers: identifiers, payloads: payloads, complete: false, nextPage: nextPage))
        } else {
            nextEnumerator?.enumerateItems(for: self, startingAt: page)
        }
    }

    func finishEnumeratingWithError(_ error: Error) {
        gate?.fail(error)
    }
}

/// Coordinates the two system-owned File Provider sets.  A callback only
/// creates a durable refresh intent; this worker consumes a bounded number of
/// pages and publishes a generation atomically.
public final class SystemSetCoordinator: @unchecked Sendable {
    private let store: SQLiteStateStore
    private let manager: NSFileProviderManager?
    private let domainIdentifier: String
    private let lockDirectory: URL
    private let ownerID = UUID()

    public init(store: SQLiteStateStore, manager: NSFileProviderManager?, domainIdentifier: String, lockDirectory: URL? = nil) {
        self.store = store
        self.manager = manager
        self.domainIdentifier = domainIdentifier
        self.lockDirectory = lockDirectory ?? AppGroupPaths.root()?.appendingPathComponent("Locks", isDirectory: true) ?? FileManager.default.temporaryDirectory.appendingPathComponent("NimbusSync-Locks", isDirectory: true)
    }

    /// Replays only durable refresh intents left by an earlier callback or
    /// process. A provider callback may be killed after returning completion;
    /// the next extension instance calls this bounded drain instead of
    /// trusting an in-memory task.
    public func drainRequiredRefreshes() async {
        if (try? store.systemSetState(setKind: "materialized")?.refreshRequired) == true {
            _ = try? await refreshMaterialized()
        }
        if (try? store.systemSetState(setKind: "pending")?.refreshRequired) == true {
            _ = try? await refreshPending()
        }
    }

    @discardableResult
    public func refreshMaterialized() async throws -> Bool {
        guard #available(macOS 13.0, *), let manager else { throw CoreFailure(code: .database, retryable: true) }
        guard let lock = POSIXAdvisoryLock(url: lockURL(for: "materialized")) else {
            try? store.markSystemSetRefreshRequired("materialized")
            return false
        }
        _ = lock
        let domainVersion = try? store.currentAnchor(domainIdentifier: domainIdentifier, scope: NSFileProviderItemIdentifier.workingSet.rawValue).encoded()
        guard let claim = try store.claimSystemSet(setKind: "materialized", ownerID: ownerID, domainVersion: domainVersion) else { return false }
        do {
            let enumerator = manager.enumeratorForMaterializedItems()
            let cursor = try store.systemSetState(setKind: "materialized")?.cursor
            let collection = try await SystemSetEnumerationCollector().collect(enumerator: enumerator, startingAt: NSFileProviderPage(cursor ?? Data()))
            for identifier in collection.itemIdentifiers {
                try store.observeMaterializedItem(identifier, claim: claim)
            }
            try store.publishMaterializedSet(claim: claim, complete: collection.complete, anchor: claim.domainVersion, cursor: collection.nextPage)
            return collection.complete
        } catch {
            try? store.releaseSystemSetClaim(claim: claim)
            throw error
        }
    }

    @discardableResult
    public func refreshPending() async throws -> Bool {
        guard #available(macOS 13.0, *), let manager else { throw CoreFailure(code: .database, retryable: true) }
        guard let lock = POSIXAdvisoryLock(url: lockURL(for: "pending")) else {
            try? store.markSystemSetRefreshRequired("pending")
            return false
        }
        _ = lock
        let domainVersion = try? store.currentAnchor(domainIdentifier: domainIdentifier, scope: NSFileProviderItemIdentifier.workingSet.rawValue).encoded()
        guard let claim = try store.claimSystemSet(setKind: "pending", ownerID: ownerID, domainVersion: domainVersion) else { return false }
        do {
            let enumerator = manager.enumeratorForPendingItems()
            let cursor = try store.systemSetState(setKind: "pending")?.cursor
            let collection = try await SystemSetEnumerationCollector().collect(enumerator: enumerator, startingAt: NSFileProviderPage(cursor ?? Data()))
            for identifier in collection.itemIdentifiers {
                try store.observePendingItem(identifier, payload: collection.payloads[identifier], claim: claim)
            }
            try store.publishPendingSet(claim: claim, complete: collection.complete, capped: enumerator.isMaximumSizeReached, anchor: nil, cursor: collection.nextPage)
            return collection.complete
        } catch {
            try? store.releaseSystemSetClaim(claim: claim)
            throw error
        }
    }

    public func applyMaterializedObservation(itemIdentifiers: [String], complete: Bool, anchor: Data? = nil, nextPage: Data? = nil) throws {
        guard let lock = POSIXAdvisoryLock(url: lockURL(for: "materialized")) else {
            try store.markSystemSetRefreshRequired("materialized")
            return
        }
        _ = lock
        guard let claim = try store.claimSystemSet(setKind: "materialized", ownerID: ownerID, domainVersion: anchor) else { return }
        do {
            for identifier in itemIdentifiers { try store.observeMaterializedItem(identifier, claim: claim) }
            try store.publishMaterializedSet(claim: claim, complete: complete, anchor: anchor, cursor: nextPage)
        } catch {
            try? store.releaseSystemSetClaim(claim: claim, cursor: nextPage)
            throw error
        }
    }

    public func applyPendingObservation(itemIdentifiers: [String], complete: Bool, capped: Bool, anchor: Data? = nil, nextPage: Data? = nil) throws {
        guard let lock = POSIXAdvisoryLock(url: lockURL(for: "pending")) else {
            try store.markSystemSetRefreshRequired("pending")
            return
        }
        _ = lock
        guard let claim = try store.claimSystemSet(setKind: "pending", ownerID: ownerID, domainVersion: anchor) else { return }
        do {
            for identifier in itemIdentifiers { try store.observePendingItem(identifier, payload: nil, claim: claim) }
            try store.publishPendingSet(claim: claim, complete: complete, capped: capped, anchor: anchor, cursor: nextPage)
        } catch {
            try? store.releaseSystemSetClaim(claim: claim, cursor: nextPage)
            throw error
        }
    }

    private func lockURL(for setKind: String) -> URL {
        lockDirectory.appendingPathComponent("system-set-\(domainIdentifier)-\(setKind).lock")
    }
}
