import Foundation
import FileProvider
import OSLog
import CloudreveDomainKit
import CloudreveStoreBridge

public struct SSEEvent: Equatable, Sendable {
    public let event: String?
    public let data: String
    public let id: String?
    public init(event: String?, data: String, id: String?) { self.event = event; self.data = data; self.id = id }
}

public enum SSEParserError: Error, Equatable { case frameTooLarge, invalidUTF8 }

public final class SSEParser: @unchecked Sendable {
    private var buffer = [UInt8]()
    private var frameBytes = 0
    private var event: String?
    private var id: String?
    private var dataLines: [String] = []
    private let maxFrameBytes: Int
    private let lock = NSLock()

    public init(maxFrameBytes: Int = 1024 * 1024) { self.maxFrameBytes = maxFrameBytes }

    public func append(_ bytes: Data) throws -> [SSEEvent] {
        try withLock {
            buffer.append(contentsOf: bytes)
            var events: [SSEEvent] = []
            while let end = lineEnd(in: buffer) {
                let lineBytes = Array(buffer.prefix(end.offset))
                buffer.removeFirst(end.offset + end.newlineLength)
                frameBytes += end.offset + end.newlineLength
                guard frameBytes <= maxFrameBytes else { throw SSEParserError.frameTooLarge }
                try consume(line: lineBytes, events: &events)
            }
            guard frameBytes + buffer.count <= maxFrameBytes else { throw SSEParserError.frameTooLarge }
            return events
        }
    }

    public func finish() throws -> [SSEEvent] {
        try withLock {
            var events: [SSEEvent] = []
            if !buffer.isEmpty { try consume(line: buffer, events: &events); buffer.removeAll(keepingCapacity: true) }
            flush(&events)
            return events
        }
    }

    private func consume(line rawLine: [UInt8], events: inout [SSEEvent]) throws {
        var line = rawLine
        if line.last == 13 { line.removeLast() }
        if line.isEmpty { flush(&events); return }
        guard let text = String(bytes: line, encoding: .utf8) else { throw SSEParserError.invalidUTF8 }
        if text.hasPrefix(":") { return }
        let split = text.firstIndex(of: ":")
        let field = split.map { String(text[..<$0]) } ?? text
        var value = split.map { String(text[text.index(after: $0)...]) } ?? ""
        if value.first == " " { value.removeFirst() }
        switch field {
        case "event": event = value
        case "data": dataLines.append(value)
        case "id": id = value
        default: break
        }
    }

    private func flush(_ events: inout [SSEEvent]) {
        guard event != nil || id != nil || !dataLines.isEmpty else {
            frameBytes = 0
            return
        }
        events.append(SSEEvent(event: event, data: dataLines.joined(separator: "\n"), id: id))
        event = nil; id = nil; dataLines.removeAll(keepingCapacity: true)
        frameBytes = 0
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
}

private struct LineEnd { let offset: Int; let newlineLength: Int }
private func lineEnd(in data: [UInt8]) -> LineEnd? {
    for index in data.indices {
        if data[index] == 10 { return LineEnd(offset: index, newlineLength: 1) }
        if data[index] == 13 {
            if index + 1 == data.count { return nil }
            return LineEnd(offset: index, newlineLength: data[index + 1] == 10 ? 2 : 1)
        }
    }
    return nil
}

public struct ReconnectPolicy: Sendable {
    public private(set) var attempt = 0
    public let maximumDelay: TimeInterval
    public init(maximumDelay: TimeInterval = 60) { self.maximumDelay = maximumDelay }
    public mutating func reset() { attempt = 0 }
    public mutating func nextDelay(jitter: TimeInterval) -> TimeInterval {
        let base = min(maximumDelay, pow(2, Double(min(attempt, 6))))
        attempt += 1
        return min(maximumDelay, max(0, min(1, jitter)) * base)
    }
}

public enum RemoteEventKind: String, Sendable { case subscribed, resumed, keepAlive = "keep-alive", reconnectRequired = "reconnect-required", file, unknown }

public struct RemoteEventHint: Sendable {
    public let kind: RemoteEventKind
    public let remoteID: String?
    public let fromURI: String?
    public let toURI: String?
    public let payload: String?
    public init(kind: RemoteEventKind, remoteID: String? = nil, fromURI: String? = nil, toURI: String? = nil, payload: String? = nil) { self.kind = kind; self.remoteID = remoteID; self.fromURI = fromURI; self.toURI = toURI; self.payload = payload }
}

public struct EchoEvidence: Sendable, Equatable {
    public let remoteID: String
    public let operationID: UUID
    public let expectedParentIdentifier: String?
    public let expectedName: String?
    public let expectedTrashed: Bool?
    public let expectedVersion: Data?
    public init(remoteID: String, operationID: UUID, expectedParentIdentifier: String? = nil, expectedName: String? = nil, expectedTrashed: Bool? = nil, expectedVersion: Data? = nil) { self.remoteID = remoteID; self.operationID = operationID; self.expectedParentIdentifier = expectedParentIdentifier; self.expectedName = expectedName; self.expectedTrashed = expectedTrashed; self.expectedVersion = expectedVersion }
}

public enum EchoMatchResult: Equatable, Sendable { case matched, realDifference, unknown }

public enum EchoMatcher {
    public static func match(_ evidence: EchoEvidence?, item: RemoteItem?) -> EchoMatchResult {
        guard let evidence, let item, evidence.remoteID == item.remoteID else { return .unknown }
        if let parent = evidence.expectedParentIdentifier, parent != item.parentIdentifier { return .realDifference }
        if let name = evidence.expectedName, name != item.name { return .realDifference }
        if let trashed = evidence.expectedTrashed, trashed != item.trashed { return .realDifference }
        if let version = evidence.expectedVersion, version != item.version.content { return .realDifference }
        return .matched
    }
}

public protocol EventStream: Sendable {
    func next() async throws -> SSEEvent?
    func cancel() async
}

public extension EventStream {
    func cancel() async {}
}

public protocol EventCoordinatorDelegate: Sendable {
    func handle(hint: RemoteEventHint) async
    func markEventDegraded() async
    func reconcile(reason: String) async
}

/// Why one stream's consumption stopped; the supervisor decides how to reconnect.
public enum EventStreamEnd: Equatable, Sendable {
    case stopped
    case ended
    case failed
    case authenticationExpired
    /// The server asked for a fresh connection; the same client ID resumes it immediately.
    case reconnectRequested
}

/// Consumes one live-update stream. A stream ending, an error, or an event this client does not
/// understand never starts a full check here: Cloudreve keeps a disconnected client's events for
/// the same client ID and replays them on `resumed`, so the delegate decides what a new
/// subscription needs.
public actor EventCoordinator {
    private let delegate: EventCoordinatorDelegate
    private var running = false

    public init(delegate: EventCoordinatorDelegate) { self.delegate = delegate }

    public func stop() { running = false }

    @discardableResult
    public func run(stream: EventStream) async -> EventStreamEnd {
        running = true
        while running && !Task.isCancelled {
            do {
                guard let event = try await stream.next() else { await delegate.markEventDegraded(); return .ended }
                if await consume(event) == .reconnectRequested { return .reconnectRequested }
            } catch let failure as CoreFailure where failure.code == .authentication {
                if let supervisorDelegate = delegate as? EventSupervisorDelegate {
                    await supervisorDelegate.markAuthenticationExpired()
                    await supervisorDelegate.setConnectionState(.authExpired)
                } else {
                    await delegate.markEventDegraded()
                }
                return .authenticationExpired
            } catch {
                await delegate.markEventDegraded()
                return .failed
            }
        }
        return .stopped
    }

    private enum ConsumeResult { case continueReading, reconnectRequested }

    private func consume(_ event: SSEEvent) async -> ConsumeResult {
        let eventName = event.event?.lowercased() ?? "message"
        let supervisorDelegate = delegate as? EventSupervisorDelegate
        switch eventName {
        case "subscribed":
            if let supervisorDelegate { await supervisorDelegate.subscriptionConfirmed(resumed: false) }
            else { await delegate.reconcile(reason: "subscribed") }
        case "resumed":
            await supervisorDelegate?.subscriptionConfirmed(resumed: true)
        case "keep-alive", "keepalive":
            await supervisorDelegate?.keepAliveReceived()
        case "reconnect-required":
            running = false
            return .reconnectRequested
        default:
            guard let name = event.event?.lowercased(), ["event", "file", "create", "modify", "rename", "delete"].contains(name), !event.data.isEmpty else {
                await supervisorDelegate?.ignoredUnrecognizedEvent()
                return .continueReading
            }
            let payloads: [RemoteEventPayload]
            if let decoded = try? JSONDecoder().decode([RemoteEventPayload].self, from: Data(event.data.utf8)) {
                payloads = decoded
            } else if let decoded = try? JSONDecoder().decode(RemoteEventPayload.self, from: Data(event.data.utf8)) {
                payloads = [decoded]
            } else {
                await supervisorDelegate?.ignoredUnrecognizedEvent()
                return .continueReading
            }
            for payload in payloads {
                let kind = RemoteEventKind(rawValue: (payload.type ?? name).lowercased()) ?? .file
                let encodedPayload = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) }
                await delegate.handle(hint: RemoteEventHint(kind: kind, remoteID: payload.id, fromURI: payload.from, toURI: payload.to, payload: encodedPayload))
            }
        }
        return .continueReading
    }
}

public protocol EventStreamFactory: Sendable {
    func open() async throws -> EventStream
}

public protocol EventSupervisorDelegate: EventCoordinatorDelegate {
    func setConnectionState(_ state: ConnectionState) async
    func markAuthenticationExpired() async
    func isAuthenticationExpired() async -> Bool
    func shouldRestartStream() async -> Bool
    /// The server's first word on a connection: `subscribed` (a new subscription, so events may
    /// have been missed) or `resumed` (the server replays what this client ID missed).
    func subscriptionConfirmed(resumed: Bool) async
    func keepAliveReceived() async
    func ignoredUnrecognizedEvent() async
}

public extension EventSupervisorDelegate {
    func markAuthenticationExpired() async { await markEventDegraded() }
    func isAuthenticationExpired() async -> Bool { false }
    func shouldRestartStream() async -> Bool { false }
    func subscriptionConfirmed(resumed: Bool) async { if !resumed { await reconcile(reason: "subscribed") } }
    func keepAliveReceived() async {}
    func ignoredUnrecognizedEvent() async {}
}

public enum ConnectionState: String, Sendable { case connecting, subscribed, degraded, offline, authExpired = "auth_expired", stopped }

/// One Domain's live-update connection as the app last observed it. In memory only: it describes
/// this process's event stream, which does not outlive the process.
public struct DomainConnectionStatus: Equatable, Sendable {
    public private(set) var state: ConnectionState
    /// When `state` last changed. Repeated reports of the same state keep the original time.
    public private(set) var since: Date
    /// The most recent successful subscription, kept across disconnects.
    public private(set) var lastConnectedAt: Date?

    public init(state: ConnectionState = .stopped, since: Date = Date(), lastConnectedAt: Date? = nil) {
        self.state = state
        self.since = since
        self.lastConnectedAt = lastConnectedAt
    }

    public func applying(_ next: ConnectionState, at date: Date = Date()) -> DomainConnectionStatus {
        guard next != state else { return self }
        var updated = self
        updated.state = next
        updated.since = date
        if next == .subscribed { updated.lastConnectedAt = date }
        return updated
    }
}

/// Owns one stream per Domain. A stream ending is a reconnect condition, not a healthy
/// completion. Connecting never starts a full check by itself: the server's `subscribed` or
/// `resumed` reply, handed to the delegate, decides that.
public actor EventSupervisor {
    private let factory: EventStreamFactory
    private let delegate: EventSupervisorDelegate
    private var policy = ReconnectPolicy()
    private var running = false
    private var activeStream: EventStream?
    private var activeCoordinator: EventCoordinator?

    public init(factory: EventStreamFactory, delegate: EventSupervisorDelegate) { self.factory = factory; self.delegate = delegate }

    public func stop() async {
        running = false
        await activeStream?.cancel()
        await activeCoordinator?.stop()
        await delegate.setConnectionState(.stopped)
    }

    public func run() async {
        running = true
        while running && !Task.isCancelled {
            await delegate.setConnectionState(.connecting)
            do {
                let stream = try await factory.open()
                let connectionStartedAt = Date()
                activeStream = stream
                await delegate.setConnectionState(.subscribed)
                if await delegate.shouldRestartStream() {
                    await stream.cancel()
                    activeStream = nil
                    continue
                }
                let coordinator = EventCoordinator(delegate: delegate)
                activeCoordinator = coordinator
                let end = await coordinator.run(stream: stream)
                activeCoordinator = nil
                activeStream = nil
                guard running else { break }
                if await delegate.isAuthenticationExpired() { break }
                if end == .reconnectRequested {
                    // The server asked for it; reconnecting with the same client ID resumes
                    // without losing events, so there is no reason to wait.
                    await stream.cancel()
                    policy.reset()
                    continue
                }
                if Date().timeIntervalSince(connectionStartedAt) >= 30 { policy.reset() }
                await delegate.setConnectionState(.degraded)
            } catch let failure as CoreFailure where failure.code == .authentication {
                await delegate.markAuthenticationExpired()
                await delegate.setConnectionState(.authExpired)
                break
            } catch {
                await delegate.setConnectionState(.degraded)
                await delegate.markEventDegraded()
            }
            let delay = policy.nextDelay(jitter: Double.random(in: 0...1))
            try? await Task.sleep(for: .seconds(delay))
        }
    }
}

public protocol WorkingSetSignaller: Sendable {
    func signalWorkingSet() async throws
}

public final class FileProviderWorkingSetSignaller: WorkingSetSignaller, @unchecked Sendable {
    private let manager: NSFileProviderManager?
    private let domain: NSFileProviderDomain?

    public init(manager: NSFileProviderManager) {
        self.manager = manager
        self.domain = nil
    }

    public init(domain: NSFileProviderDomain) {
        self.manager = nil
        self.domain = domain
    }

    public func signalWorkingSet() async throws {
        let resolvedManager: NSFileProviderManager?
        if let manager {
            resolvedManager = manager
        } else if let domain {
            resolvedManager = NSFileProviderManager(for: domain)
        } else {
            resolvedManager = nil
        }
        guard let resolvedManager else { throw CoreFailure(code: .database, retryable: true) }
        try await resolvedManager.signalEnumerator(for: .workingSet)
    }
}

public actor SignalOutboxDrainer {
    private let store: SQLiteStateStore
    private let signaller: WorkingSetSignaller
    private let logger = Logger(subsystem: "ai.tiy.nimbussync", category: "signal-outbox")

    public init(store: SQLiteStateStore, signaller: WorkingSetSignaller) { self.store = store; self.signaller = signaller }

    @discardableResult
    public func drain() async -> Bool {
        while true {
            do {
                guard let revision = try store.latestPendingOutboxRevision() else { return true }
                logger.info("signal.attempt revision=\(revision, privacy: .public)")
                try await signaller.signalWorkingSet()
                try store.acknowledgeOutbox(upTo: revision)
                logger.info("signal.acknowledged revision=\(revision, privacy: .public)")
            } catch {
                logger.error("signal.failed code=\(reconciliationErrorCode(error), privacy: .public)")
                return false
            }
        }
    }
}

public struct EnrichedRemoteChange: Sendable, Equatable {
    public let item: RemoteItem
    public let oldParentIdentifier: String?
    public let newParentIdentifier: String?
    public let kind: String
    public init(item: RemoteItem, oldParentIdentifier: String?, newParentIdentifier: String?, kind: String) { self.item = item; self.oldParentIdentifier = oldParentIdentifier; self.newParentIdentifier = newParentIdentifier; self.kind = kind }
}

public actor EventJournalWriter {
    private let store: SQLiteStateStore
    private let outboxDrainer: SignalOutboxDrainer?
    private var commitsSinceCompaction = 0

    public init(store: SQLiteStateStore, outboxDrainer: SignalOutboxDrainer? = nil) { self.store = store; self.outboxDrainer = outboxDrainer }

    private func maintainStorage() {
        commitsSinceCompaction += 1
        guard commitsSinceCompaction >= 256 else { return }
        commitsSinceCompaction = 0
        try? store.compactJournal()
        try? store.compactTransferState()
    }

    public func commit(_ change: EnrichedRemoteChange) async throws -> JournalChange? {
        let visibility = try store.isExcludedByCurrentRules(item: change.item)
        let previousItem = try store.item(identifier: change.item.itemIdentifier)
        let previousState = try store.localItemState(identifier: change.item.itemIdentifier)
        let explicitViewState: Bool?
        switch change.kind.lowercased() {
        case "view_removed": explicitViewState = true
        case "view_added": explicitViewState = false
        default: explicitViewState = nil
        }
        if let explicitViewState {
            if previousItem == nil || previousState.viewExcluded != explicitViewState {
                let journal = try store.commitProviderViewChange(
                    item: change.item,
                    oldParentIdentifier: change.oldParentIdentifier ?? previousItem?.parentIdentifier,
                    newParentIdentifier: change.newParentIdentifier ?? change.item.parentIdentifier,
                    excluded: explicitViewState,
                    origin: "remote_event"
                )
                if let outboxDrainer, !(await outboxDrainer.drain()) { throw CoreFailure(code: .network, retryable: true) }
                maintainStorage()
                return journal
            }
            try store.insertItem(change.item)
            return nil
        }
        if visibility.excluded {
            let shouldEmit = previousItem == nil || !previousState.viewExcluded
            if shouldEmit {
                let journal = try store.commitProviderViewChange(item: change.item, oldParentIdentifier: change.oldParentIdentifier ?? previousItem?.parentIdentifier, newParentIdentifier: change.newParentIdentifier ?? change.item.parentIdentifier, excluded: true, origin: "remote_event")
                if let outboxDrainer, !(await outboxDrainer.drain()) { throw CoreFailure(code: .network, retryable: true) }
                maintainStorage()
                return journal
            }
            try store.insertItem(change.item)
            return nil
        }
        if previousState.viewExcluded {
            let journal = try store.commitProviderViewChange(item: change.item, oldParentIdentifier: change.oldParentIdentifier ?? previousItem?.parentIdentifier, newParentIdentifier: change.newParentIdentifier ?? change.item.parentIdentifier, excluded: false, origin: "remote_event")
            if let outboxDrainer, !(await outboxDrainer.drain()) { throw CoreFailure(code: .network, retryable: true) }
            maintainStorage()
            return journal
        }
        if let existing = previousItem,
           existing.remoteID == change.item.remoteID,
           existing.parentIdentifier == change.item.parentIdentifier,
           existing.name == change.item.name,
           existing.uri == change.item.uri,
           existing.kind == change.item.kind,
           existing.contentType == change.item.contentType,
           existing.size == change.item.size,
           existing.remoteVersion == change.item.remoteVersion,
           existing.creationDate == change.item.creationDate,
           existing.contentModificationDate == change.item.contentModificationDate,
           existing.canRead == change.item.canRead,
           existing.canWrite == change.item.canWrite,
           existing.canAddChildren == change.item.canAddChildren,
           existing.canTrash == change.item.canTrash,
           existing.canDelete == change.item.canDelete,
           existing.trashOriginalParentIdentifier == change.item.trashOriginalParentIdentifier,
           existing.trashed == change.item.trashed,
           existing.tombstone == change.item.tombstone,
           existing.version == change.item.version {
            return nil
        }
        let journal = try store.commitProviderChange(item: change.item, oldParentIdentifier: change.oldParentIdentifier ?? previousItem?.parentIdentifier, newParentIdentifier: change.newParentIdentifier ?? change.item.parentIdentifier, kind: change.kind, origin: "remote_event")
        if let outboxDrainer, !(await outboxDrainer.drain()) {
            throw CoreFailure(code: .network, retryable: true)
        }
        maintainStorage()
        return journal
    }

    public func commit(_ changes: [EnrichedRemoteChange]) async throws -> [JournalChange] {
        guard !changes.isEmpty else { return [] }
        // Fold one producer result before allocating sequence numbers, then
        // pass each folded change through the same visibility, exclusion and
        // descendant-refresh path as a single event. This keeps batch and
        // live-event semantics identical; a process kill between two rows is
        // safe because the retry sees the already-persisted final projection.
        let folded = JournalChangeFold.fold(changes.map {
            ProviderChangeInput(item: $0.item, oldParentIdentifier: $0.oldParentIdentifier, newParentIdentifier: $0.newParentIdentifier, kind: $0.kind, origin: "remote_event")
        })
        var journals: [JournalChange] = []
        for input in folded {
            let change = EnrichedRemoteChange(item: input.item, oldParentIdentifier: input.oldParentIdentifier, newParentIdentifier: input.newParentIdentifier, kind: input.kind)
            if let journal = try await commit(change) {
                journals.append(journal)
            }
        }
        return journals
    }

    public func markReconcileStatus(_ status: String, at date: Date = Date()) {
        try? store.updateSyncState(reconcileAt: status == "completed" ? date : nil, reconcileStatus: status)
    }
}

public struct ReconcileScheduler: Sendable {
    public let workingInterval: TimeInterval
    public let fullInterval: TimeInterval
    public init(workingInterval: TimeInterval = 6 * 60 * 60, fullInterval: TimeInterval = 24 * 60 * 60) { self.workingInterval = workingInterval; self.fullInterval = fullInterval }
    public func shouldReconcile(lastWorking: Date?, lastFull: Date?, now: Date = Date(), reason: String? = nil) -> Bool {
        if reason != nil { return true }
        if lastWorking.map({ now.timeIntervalSince($0) >= workingInterval }) ?? true { return true }
        return lastFull.map({ now.timeIntervalSince($0) >= fullInterval }) ?? true
    }
}

/// How often the background fallback check runs. Live updates carry everyday changes; the
/// fallback only catches what the server never delivered (it drops events past a small
/// per-client queue during bursts).
public enum FullCheckInterval: Int, CaseIterable, Identifiable, Sendable {
    case daily = 1
    case weekly = 7
    case monthly = 30

    public static let defaultValue: FullCheckInterval = .weekly
    public static let preferenceKey = "fullCheck.intervalDays"

    public var id: Int { rawValue }
    public var seconds: TimeInterval { TimeInterval(rawValue) * 24 * 60 * 60 }

    public var title: String {
        switch self {
        case .daily: "Every day"
        case .weekly: "Every 7 days"
        case .monthly: "Every 30 days"
        }
    }

    public static func stored(in defaults: UserDefaults = .standard) -> FullCheckInterval {
        FullCheckInterval(rawValue: defaults.integer(forKey: preferenceKey)) ?? defaultValue
    }
}

/// When a Domain needs a full check. A full check lists every folder on the server, so it runs
/// only when nothing cheaper can be trusted.
public enum FullCheckPolicy {
    /// The reason to check after the server confirms a subscription, or nil to rely on the
    /// replayed events.
    ///
    /// - `subscribed` is a new subscription: the server kept nothing for this client ID (first
    ///   connection, server restart, or offline past its retention), so changes may be missing.
    /// - A Domain that never finished a check has no complete local view yet; that first check
    ///   is retried once per app session until it completes.
    public static func reasonAfterSubscription(resumed: Bool, hasCompletedCheck: Bool, initialCheckAttemptedThisSession: Bool) -> String? {
        if !resumed { return "subscribed" }
        if !hasCompletedCheck && !initialCheckAttemptedThisSession { return "initial" }
        return nil
    }

    /// Due once the interval has passed since the last check started, whether or not that
    /// check succeeded, so a failing check is not retried in a loop.
    public static func isFallbackDue(lastAttempt: Date?, interval: TimeInterval, now: Date = Date()) -> Bool {
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= interval
    }

    /// Replaying more changes than the Domain has items costs more than listing it once.
    public static func replayCalledForFullCheck(replayedEvents: Int, itemCount: Int) -> Bool {
        replayedEvents > itemCount
    }
}
