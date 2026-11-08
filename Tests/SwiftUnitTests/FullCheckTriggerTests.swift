import XCTest
import Foundation
import FileProvider
import CloudreveAuthKit
import CloudreveDomainKit
import CloudreveEventCoordinator
import CloudreveStoreBridge

/// A full check lists every folder on the server, so it runs only when nothing cheaper can be
/// trusted. Cloudreve keeps a disconnected client's events for its client ID (14 days by
/// default) and replays them on `resumed`; reconnecting is therefore not a reason to check.
final class FullCheckTriggerTests: XCTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        for url in cleanup {
            for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        cleanup.removeAll()
        super.tearDown()
    }

    // MARK: - Policy

    func testSubscriptionPolicyChecksOnlyNewSubscriptionsAndUnfinishedDomains() {
        XCTAssertEqual(FullCheckPolicy.reasonAfterSubscription(resumed: false, hasCompletedCheck: true, initialCheckAttemptedThisSession: true), "subscribed", "the server kept nothing for this client")
        XCTAssertNil(FullCheckPolicy.reasonAfterSubscription(resumed: true, hasCompletedCheck: true, initialCheckAttemptedThisSession: false), "a resumed subscription replays what was missed")
        XCTAssertEqual(FullCheckPolicy.reasonAfterSubscription(resumed: true, hasCompletedCheck: false, initialCheckAttemptedThisSession: false), "initial", "a new domain needs its first check")
        XCTAssertNil(FullCheckPolicy.reasonAfterSubscription(resumed: true, hasCompletedCheck: false, initialCheckAttemptedThisSession: true), "a failed first check is not retried on every reconnect")
    }

    func testFallbackIsDueByLastAttemptWhetherOrNotItSucceeded() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let week = FullCheckInterval.weekly.seconds
        XCTAssertTrue(FullCheckPolicy.isFallbackDue(lastAttempt: nil, interval: week, now: now))
        XCTAssertFalse(FullCheckPolicy.isFallbackDue(lastAttempt: now.addingTimeInterval(-week + 60), interval: week, now: now))
        XCTAssertTrue(FullCheckPolicy.isFallbackDue(lastAttempt: now.addingTimeInterval(-week), interval: week, now: now))
    }

    func testReplayLargerThanTheDomainCallsForAFullCheck() {
        XCTAssertFalse(FullCheckPolicy.replayCalledForFullCheck(replayedEvents: 100, itemCount: 100))
        XCTAssertTrue(FullCheckPolicy.replayCalledForFullCheck(replayedEvents: 101, itemCount: 100))
    }

    func testIntervalPreferenceDefaultsToWeeklyAndOffersDayWeekMonth() throws {
        XCTAssertEqual(FullCheckInterval.allCases.map(\.rawValue), [1, 7, 30])
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "nimbussync-full-check-\(UUID().uuidString)"))
        XCTAssertEqual(FullCheckInterval.stored(in: defaults), .weekly)
        defaults.set(30, forKey: FullCheckInterval.preferenceKey)
        XCTAssertEqual(FullCheckInterval.stored(in: defaults), .monthly)
        defaults.set(3, forKey: FullCheckInterval.preferenceKey)
        XCTAssertEqual(FullCheckInterval.stored(in: defaults), .weekly, "an unknown value falls back to the default")
    }

    // MARK: - Event stream

    func testStreamEventsNeverStartAFullCheckThemselves() async {
        let delegate = RecordingSupervisorDelegate()
        let coordinator = EventCoordinator(delegate: delegate)
        let end = await coordinator.run(stream: ScriptedStream(events: [
            SSEEvent(event: "resumed", data: "", id: nil),
            SSEEvent(event: "keep-alive", data: "", id: nil),
            SSEEvent(event: "mystery", data: "{}", id: nil),
            SSEEvent(event: "event", data: "not json", id: nil),
        ]))
        XCTAssertEqual(end, .ended)
        let record = await delegate.record
        XCTAssertEqual(record.subscriptions, [true])
        XCTAssertEqual(record.keepAlives, 1)
        XCTAssertEqual(record.ignored, 2, "unknown and malformed events are skipped")
        XCTAssertEqual(record.reconciles, [], "neither odd events nor the stream ending start a check")
    }

    func testNewSubscriptionIsReportedAndReconnectRequestEndsTheStream() async {
        let delegate = RecordingSupervisorDelegate()
        let end = await EventCoordinator(delegate: delegate).run(stream: ScriptedStream(events: [
            SSEEvent(event: "subscribed", data: "", id: nil),
            SSEEvent(event: "reconnect-required", data: "", id: nil),
            SSEEvent(event: "resumed", data: "", id: nil),
        ]))
        XCTAssertEqual(end, .reconnectRequested)
        let record = await delegate.record
        XCTAssertEqual(record.subscriptions, [false], "events after reconnect-required are not read")
        XCTAssertEqual(record.reconciles, [])
    }

    func testSupervisorReconnectsAtOnceWhenAskedAndNeverChecksOnConnect() async throws {
        let delegate = RecordingSupervisorDelegate()
        let factory = ScriptedStreamFactory(scripts: [
            [SSEEvent(event: "resumed", data: "", id: nil), SSEEvent(event: "reconnect-required", data: "", id: nil)],
            [SSEEvent(event: "resumed", data: "", id: nil)],
        ])
        let supervisor = EventSupervisor(factory: factory, delegate: delegate)
        let task = Task { await supervisor.run() }
        for _ in 0..<200 where await factory.openCount < 2 { try await Task.sleep(for: .milliseconds(10)) }
        await supervisor.stop()
        task.cancel()
        _ = await task.value

        let opens = await factory.openCount
        XCTAssertGreaterThanOrEqual(opens, 2)
        let record = await delegate.record
        XCTAssertEqual(record.reconciles, [], "connecting is not a reason to check")
        XCTAssertEqual(Array(record.states.prefix(4)), [.connecting, .subscribed, .connecting, .subscribed], "a requested reconnect skips the degraded state and the backoff")
    }

    // MARK: - Runtime

    func testResumedDomainBecomesCurrentWithoutAFullCheck() async throws {
        let (store, descriptor) = try makeDomain()
        try store.updateSyncState(reconcileAt: Date().addingTimeInterval(-3_600), reconcileStatus: "completed")
        try store.setDomainStatus(identifier: descriptor.identifier, status: .appNotRunning)
        let runtime = try XCTUnwrap(DomainEventRuntime(descriptor: descriptor, store: store, vault: MemoryCredentialVault()))

        await runtime.subscriptionConfirmed(resumed: true)

        let checking = await runtime.isRunningFullCheck()
        XCTAssertFalse(checking)
        XCTAssertEqual(try store.domain(identifier: descriptor.identifier)?.status, .healthy)
        XCTAssertNil(try store.lastFullCheckAttemptAt(), "no check was started")
    }

    func testResumeLeavesProblemsThatNeedTheUserVisible() async throws {
        let (store, descriptor) = try makeDomain()
        try store.updateSyncState(reconcileAt: Date(), reconcileStatus: "completed")
        try store.setDomainStatus(identifier: descriptor.identifier, status: .rootUnavailable)
        let runtime = try XCTUnwrap(DomainEventRuntime(descriptor: descriptor, store: store, vault: MemoryCredentialVault()))
        await runtime.subscriptionConfirmed(resumed: true)
        XCTAssertEqual(try store.domain(identifier: descriptor.identifier)?.status, .rootUnavailable)
    }

    func testFallbackWaitsForTheConnectionAndTheInterval() async throws {
        let (store, descriptor) = try makeDomain()
        let runID = UUID()
        try store.startReconcile(runID: runID, scope: descriptor.currentRootURI, generation: 1, phase: "prepared", cursor: nil)
        try store.updateReconcile(runID: runID, phase: "failed", cursor: nil, state: "failed")
        let runtime = try XCTUnwrap(DomainEventRuntime(descriptor: descriptor, store: store, vault: MemoryCredentialVault()))

        var started = await runtime.startFallbackCheckIfDue(interval: 0)
        XCTAssertFalse(started, "no fallback check without a live connection")
        await runtime.setConnectionState(.subscribed)
        started = await runtime.startFallbackCheckIfDue(interval: FullCheckInterval.daily.seconds)
        XCTAssertFalse(started, "a failed check still counts as the last attempt")
    }

    // MARK: - Store

    func testStoreTracksAttemptsAndItemCount() throws {
        let (store, descriptor) = try makeDomain()
        XCTAssertNil(try store.lastFullCheckAttemptAt())
        XCTAssertEqual(try store.remoteItemCount(), 0)

        let runID = UUID()
        try store.startReconcile(runID: runID, scope: descriptor.currentRootURI, generation: 1, phase: "prepared", cursor: nil)
        try store.updateReconcile(runID: runID, phase: "failed", cursor: "page:3", state: "failed")
        let firstAttempt = try XCTUnwrap(store.lastFullCheckAttemptAt())
        XCTAssertEqual(firstAttempt.timeIntervalSinceNow, 0, accuracy: 5)
        try store.markReconcileAttempt(runID: runID)
        XCTAssertEqual(try store.activeReconcileRuns().first?.state, "active")
        XCTAssertEqual(try store.activeReconcileRuns().first?.cursor, "page:3", "a resumed attempt keeps its cursor")

        func item(_ remoteID: String) -> RemoteItem {
            RemoteItem(remoteID: remoteID, parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "\(remoteID).txt", uri: "cloudreve://my/\(remoteID).txt", kind: .file, contentType: "public.data", size: 1, version: ItemVersion(content: Data(remoteID.utf8), metadata: Data(remoteID.utf8)))
        }
        let gone = item("r-gone")
        try store.insertItems([item("r-a"), item("r-b"), gone])
        var tombstone = gone
        tombstone.tombstone = true
        try store.insertItem(tombstone)
        XCTAssertEqual(try store.remoteItemCount(), 2, "deleted items do not count")
    }

    // MARK: - Fixture

    private func makeDomain() throws -> (SQLiteStateStore, DomainDescriptor) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-full-check-\(UUID().uuidString).sqlite3")
        cleanup.append(url)
        let store = try SQLiteStateStore(url: url)
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "cloudreve://my/")
        let descriptor = DomainDescriptor(identifier: "crd-44444444-4444-4444-8444-444444444444", displayName: "Full check", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential-ref")
        try store.registerDomain(descriptor)
        return (store, descriptor)
    }
}

private struct DelegateRecord: Sendable {
    var subscriptions: [Bool] = []
    var keepAlives = 0
    var ignored = 0
    var reconciles: [String] = []
    var states: [ConnectionState] = []
}

private actor RecordingSupervisorDelegate: EventSupervisorDelegate {
    private(set) var record = DelegateRecord()
    func handle(hint: RemoteEventHint) async {}
    func markEventDegraded() async {}
    func reconcile(reason: String) async { record.reconciles.append(reason) }
    func setConnectionState(_ state: ConnectionState) async { record.states.append(state) }
    func subscriptionConfirmed(resumed: Bool) async { record.subscriptions.append(resumed) }
    func keepAliveReceived() async { record.keepAlives += 1 }
    func ignoredUnrecognizedEvent() async { record.ignored += 1 }
}

private actor ScriptedStream: EventStream {
    private var events: [SSEEvent]
    init(events: [SSEEvent]) { self.events = events }
    func next() async throws -> SSEEvent? { events.isEmpty ? nil : events.removeFirst() }
}

private actor ScriptedStreamFactory: EventStreamFactory {
    private var scripts: [[SSEEvent]]
    private(set) var openCount = 0
    init(scripts: [[SSEEvent]]) { self.scripts = scripts }
    func open() async throws -> EventStream {
        openCount += 1
        return ScriptedStream(events: scripts.isEmpty ? [] : scripts.removeFirst())
    }
}

/// What Cloudreve actually sends (gin's `c.SSEvent`), fed byte by byte as the stream reads it.
final class SSEByteFeederTests: XCTestCase {
    func testEventsAreDispatchedAtTheEmptyLineThatEndsThem() throws {
        let wire = "event:resumed\ndata:null\n\nevent:event\ndata:{\"type\":\"create\",\"file_id\":\"a1\",\"from\":\"/x.txt\",\"to\":\"\"}\n\nevent:keep-alive\ndata:null\n\n"
        var feeder = SSEByteFeeder()
        var events: [SSEEvent] = []
        for byte in Array(wire.utf8) { events += try feeder.append(byte) }
        XCTAssertEqual(events.map(\.event), ["resumed", "event", "keep-alive"], "each event arrives as soon as its empty line does, not when the stream ends")
        XCTAssertTrue(events[1].data.contains("\"file_id\":\"a1\""))
        XCTAssertEqual(try feeder.finish(), [])
    }

    func testCarriageReturnLineEndingsAlsoEndEvents() throws {
        var feeder = SSEByteFeeder()
        var events: [SSEEvent] = []
        for byte in Array("event:subscribed\r\ndata:null\r\n\r\n".utf8) { events += try feeder.append(byte) }
        XCTAssertEqual(events.map(\.event), ["subscribed"])
    }

    func testAnEndlessLineIsRejected() {
        var feeder = SSEByteFeeder(maximumLineBytes: 64)
        XCTAssertThrowsError(try (0..<100).forEach { _ in _ = try feeder.append(UInt8(ascii: "x")) })
    }
}
