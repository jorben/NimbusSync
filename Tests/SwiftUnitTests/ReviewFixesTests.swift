import XCTest
import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveFileProviderKit

/// Regression tests for the review findings: capability baseline, shared item
/// mapping, metadata versions, xattr policy, replayable failures and
/// automatic conflict copies.
final class ReviewFixesTests: XCTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        for url in cleanup {
            try? FileManager.default.removeItem(at: url)
            for suffix in ["-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        cleanup.removeAll()
        super.tearDown()
    }

    private func temporaryURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-review-\(name)-\(UUID().uuidString)")
        cleanup.append(url)
        return url
    }

    private func makeStore(capabilities: CapabilitySnapshot = .cloudreveV4(serverVersion: "4.0.0")) throws -> (SQLiteStateStore, String) {
        let store = try SQLiteStateStore(url: temporaryURL("store.sqlite3"))
        let domainID = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: domainID, displayName: "Review", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential", capabilitySnapshot: capabilities))
        return (store, domainID)
    }

    private func context(_ identifier: String) -> FileProviderOperationContext {
        FileProviderOperationContext(itemIdentifier: NSFileProviderItemIdentifier(identifier), progress: Progress(totalUnitCount: 1), registrar: NoopURLSessionTaskRegistrar(), cancellation: CancellationToken())
    }

    // MARK: Capability baseline

    func testUnprobedSnapshotUpgradesToCloudreveV4Baseline() {
        let legacy = CapabilitySnapshot(serverVersion: "4.3.0")
        XCTAssertTrue(legacy.isUnprobedDefault)
        XCTAssertFalse(legacy.allowsCreate)

        let upgraded = legacy.upgradedToCloudreveV4Baseline()
        XCTAssertEqual(upgraded, .cloudreveV4(serverVersion: "4.3.0"))
        XCTAssertTrue(upgraded.allowsCreate)
        XCTAssertTrue(upgraded.allowsMetadataMove)
        XCTAssertTrue(upgraded.allowsContentWrite)
        XCTAssertTrue(upgraded.canTrash)
        XCTAssertTrue(upgraded.canPurge)
        for policy in CapabilitySnapshot.cloudreveV4UploadPolicies {
            XCTAssertTrue(upgraded.canWrite(provider: policy), policy)
            XCTAssertTrue(upgraded.canWriteZeroByte(provider: policy), policy)
        }

        // Explicitly configured snapshots are never rewritten.
        let explicit = CapabilitySnapshot(revision: 5, completePagination: .verified)
        XCTAssertFalse(explicit.isUnprobedDefault)
        XCTAssertEqual(explicit.upgradedToCloudreveV4Baseline(), explicit)
    }

    func testStoreUpgradesLegacyDefaultSnapshotOnRead() throws {
        let (store, domainID) = try makeStore(capabilities: CapabilitySnapshot())
        let stored = try XCTUnwrap(store.domain(identifier: domainID))
        XCTAssertEqual(stored.capabilitySnapshot.revision, CapabilitySnapshot.cloudreveV4BaselineRevision)
        XCTAssertTrue(stored.capabilitySnapshot.allowsCreate)
        XCTAssertTrue(try XCTUnwrap(store.allDomains().first).capabilitySnapshot.allowsContentWrite)
    }

    // MARK: Shared item mapper

    func testItemMapperAppliesOneRuleSet() {
        let capabilities = CapabilitySnapshot.cloudreveV4(serverVersion: nil)
        let root = NSFileProviderItemIdentifier.rootContainer.rawValue
        func map(type: Int, name: String, capability: String?, entity: String? = "entity-1", snapshot: CapabilitySnapshot = capabilities) -> RemoteItem {
            let fields = CloudreveFileFields(type: type, id: "remote-\(name)", name: name, size: 10, permission: nil, capability: capability, createdAt: "2026-11-08T10:00:00.123+08:00", updatedAt: "2026-11-08T10:00:00Z", primaryEntity: entity)
            return CloudreveItemMapper.item(from: fields, normalizedURI: "cloudreve://account@my/\(name)", parentIdentifier: root, itemIdentifier: CloudreveIdentifier.item(), capabilities: snapshot)
        }

        let file = map(type: 0, name: "Report.PDF", capability: "rwd")
        XCTAssertEqual(file.kind, .file)
        XCTAssertEqual(file.contentType, UTType.pdf.identifier)
        XCTAssertTrue(file.canRead)
        XCTAssertTrue(file.canWrite)
        XCTAssertTrue(file.canTrash)
        XCTAssertTrue(file.canDelete)
        XCTAssertFalse(file.canAddChildren)
        XCTAssertNotNil(file.creationDate, "fractional-second timestamps must parse")
        XCTAssertNotNil(file.contentModificationDate)

        let readOnly = map(type: 0, name: "shared.txt", capability: "r")
        XCTAssertFalse(readOnly.canWrite)
        XCTAssertFalse(readOnly.canTrash)
        XCTAssertFalse(readOnly.canDelete)

        let folder = map(type: 1, name: "Projects", capability: "rwd")
        XCTAssertEqual(folder.contentType, UTType.folder.identifier)
        XCTAssertTrue(folder.canAddChildren)
        XCTAssertTrue(folder.canWrite)

        // Without a reliable content version, content writes stay closed.
        XCTAssertFalse(map(type: 0, name: "unversioned.bin", capability: "rwd", entity: nil).canWrite)
        // Unknown extensions fall back to generic data.
        XCTAssertEqual(map(type: 0, name: "blob.zz9unknown", capability: "rw").contentType, UTType.data.identifier)
        // An explicitly unverified snapshot keeps every write closed.
        let closed = map(type: 1, name: "Locked", capability: "rwd", snapshot: CapabilitySnapshot(revision: 9))
        XCTAssertFalse(closed.canAddChildren)
        XCTAssertFalse(closed.canWrite)
        XCTAssertFalse(closed.canTrash)
    }

    // MARK: Metadata version

    func testMetadataVersionIgnoresTransientTransferState() {
        let item = RemoteItem(remoteID: "remote-version", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "a.txt", uri: "/a.txt", kind: .file, contentType: "public.plain-text", version: ItemVersion(content: Data("c".utf8), metadata: Data("m".utf8)), canRead: true, canWrite: true, canTrash: true)
        var dataless = ItemLocalState()
        dataless.materialized = false
        var downloaded = ItemLocalState()
        downloaded.materialized = true
        var downloading = ItemLocalState()
        downloading.downloadState = .running

        let a = NimbusSyncFileProviderItem(projection: ItemProjection(item: item, localState: dataless, childItemCount: 1))
        let b = NimbusSyncFileProviderItem(projection: ItemProjection(item: item, localState: downloaded, childItemCount: 7))
        let c = NimbusSyncFileProviderItem(projection: ItemProjection(item: item, localState: downloading))
        XCTAssertEqual(a.itemVersion.metadataVersion, b.itemVersion.metadataVersion)
        XCTAssertEqual(a.itemVersion.metadataVersion, c.itemVersion.metadataVersion)
        XCTAssertTrue(b.isDownloaded, "transient state is still projected on the item")

        // Durable, user-visible policy still versions the metadata.
        var kept = ItemLocalState()
        kept.keepPolicy = .keepDownloaded
        let d = NimbusSyncFileProviderItem(projection: ItemProjection(item: item, localState: kept))
        XCTAssertNotEqual(a.itemVersion.metadataVersion, d.itemVersion.metadataVersion)
    }

    func testNonTrashedItemsAllowDeletingSoRmIsNotRejected() {
        let item = RemoteItem(remoteID: "remote-delete", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "tmp.lock", uri: "/tmp.lock", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("c".utf8), metadata: Data("m".utf8)), canRead: true, canWrite: true, canTrash: true)
        let projected = NimbusSyncFileProviderItem(model: item)
        XCTAssertTrue(projected.capabilities.contains(.allowsTrashing))
        XCTAssertTrue(projected.capabilities.contains(.allowsDeleting))

        let root = RemoteItem(itemIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "Root", uri: "/", kind: .folder, contentType: UTType.folder.identifier, version: ItemVersion(content: Data("root".utf8), metadata: Data("root".utf8)), canRead: true, canWrite: true, canAddChildren: true, canTrash: true, canDelete: true)
        let projectedRoot = NimbusSyncFileProviderItem(model: root)
        XCTAssertTrue(projectedRoot.capabilities.contains(.allowsAddingSubItems))
        XCTAssertFalse(projectedRoot.capabilities.contains(.allowsDeleting))
        XCTAssertFalse(projectedRoot.capabilities.contains(.allowsTrashing))
        XCTAssertFalse(projectedRoot.capabilities.contains(.allowsRenaming))
        XCTAssertFalse(projectedRoot.capabilities.contains(.allowsReparenting))
    }

    // MARK: Special files

    func testFilesWithExtendedAttributesRemainSyncable() throws {
        let url = temporaryURL("xattr.txt")
        try Data("hello".utf8).write(to: url)
        for name in ["com.apple.TextEncoding", "com.apple.lastuseddate#PS", "com.apple.metadata:_kMDItemUserTags", "com.example.custom"] {
            let value = Data("value".utf8)
            let result = value.withUnsafeBytes { buffer in
                setxattr(url.path, name, buffer.baseAddress, buffer.count, 0, 0)
            }
            XCTAssertEqual(result, 0, name)
        }
        XCTAssertEqual(try SpecialFilePolicy.decision(for: url), .syncable)
    }

    // MARK: Conflict copies

    func testConflictCopyNamingKeepsExtension() {
        let name = ConflictCopyNaming.name(for: "report.docx")
        XCTAssertTrue(name.hasPrefix("report (Conflict "), name)
        XCTAssertTrue(name.hasSuffix(").docx"), name)
        let bare = ConflictCopyNaming.name(for: "Makefile")
        XCTAssertTrue(bare.hasPrefix("Makefile (Conflict "), bare)
        XCTAssertTrue(bare.hasSuffix(")"), bare)
    }

    func testStaleContentEditIsPreservedAsConflictCopy() async throws {
        let (store, _) = try makeStore()
        let base = RemoteItem(remoteID: "remote-notes", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "notes.txt", uri: "/notes.txt", kind: .file, contentType: "public.plain-text", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true, canWrite: true, canTrash: true)
        try store.insertItem(base)
        var remote = base
        remote.version = ItemVersion(content: Data("v2".utf8), metadata: Data("m2".utf8))
        let remoteBytes = Data("server edit".utf8)
        let memory = MemoryFileProviderBackend(items: [remote], contents: [base.itemIdentifier: remoteBytes])

        let localBytes = Data("local edit".utf8)
        let source = temporaryURL("local-edit.txt")
        try localBytes.write(to: source)

        let outcome = try await AsyncFileProviderMutationCoordinator(store: store, backend: LegacyAsyncFileProviderBackendAdapter(backend: memory))
            .modifyResolvingConflicts(item: base, baseVersion: base.version.content, fields: [.contents], contents: source, options: [], context: context(base.itemIdentifier))

        XCTAssertTrue(outcome.shouldFetchContent, "the system must re-download the server version")
        XCTAssertEqual(outcome.item.itemIdentifier, base.itemIdentifier)
        XCTAssertEqual(outcome.item.version.content, Data("v2".utf8))
        let copy = try XCTUnwrap(outcome.conflictCopy)
        XCTAssertTrue(copy.name.hasPrefix("notes (Conflict "))
        XCTAssertEqual(copy.parentIdentifier, base.parentIdentifier)
        XCTAssertEqual(try memory.content(identifier: copy.itemIdentifier, expectedVersion: nil), localBytes, "local bytes are preserved")
        XCTAssertEqual(try memory.content(identifier: base.itemIdentifier, expectedVersion: nil), remoteBytes, "the server version is not overwritten")
        XCTAssertNotNil(try store.item(identifier: copy.itemIdentifier))
        XCTAssertEqual(try store.pendingConflictCount(), 0)
        XCTAssertFalse(try store.hasPendingWork(itemIdentifier: base.itemIdentifier))
    }

    // MARK: Replayable failures

    func testTransientFailureIsReplayedInsteadOfWedgingTheItem() async throws {
        let (store, _) = try makeStore()
        let item = RemoteItem(remoteID: "remote-flaky", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "flaky.txt", uri: "/flaky.txt", kind: .file, contentType: "public.plain-text", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true, canWrite: true, canTrash: true)
        try store.insertItem(item)
        let flaky = FlakyModifyBackend(memory: MemoryFileProviderBackend(items: [item], contents: [item.itemIdentifier: Data("v1".utf8)]), failures: 1)
        let coordinator = AsyncFileProviderMutationCoordinator(store: store, backend: LegacyAsyncFileProviderBackendAdapter(backend: flaky))
        let source = temporaryURL("flaky.txt")
        try Data("edit".utf8).write(to: source)

        do {
            _ = try await coordinator.modify(item: item, baseVersion: item.version.content, fields: [.contents], contents: source, options: [], context: context(item.itemIdentifier))
            XCTFail("the injected network failure must escape")
        } catch let failure as CoreFailure {
            XCTAssertEqual(failure.code, .network)
        }
        XCTAssertEqual(try store.latestOperation(itemIdentifier: item.itemIdentifier)?.operation.state, "retry_pending")

        // The system replays the identical callback: it must run again.
        let updated = try await coordinator.modify(item: item, baseVersion: item.version.content, fields: [.contents], contents: source, options: [], context: context(item.itemIdentifier))
        XCTAssertEqual(updated.itemIdentifier, item.itemIdentifier)
        XCTAssertEqual(try store.latestOperation(itemIdentifier: item.itemIdentifier)?.operation.state, "committed")
        XCTAssertEqual(flaky.modifyCalls, 2)
    }

    func testNewerEditSupersedesAFailedAttempt() async throws {
        let (store, _) = try makeStore()
        let item = RemoteItem(remoteID: "remote-supersede", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "doc.txt", uri: "/doc.txt", kind: .file, contentType: "public.plain-text", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true, canWrite: true, canTrash: true)
        try store.insertItem(item)
        _ = try store.upsertOperation(PendingOperation(replayKey: "modify|stale-attempt", kind: "modify", itemIdentifier: item.itemIdentifier, state: "unknown_outcome"))
        let memory = MemoryFileProviderBackend(items: [item], contents: [item.itemIdentifier: Data("v1".utf8)])
        let source = temporaryURL("doc.txt")
        try Data("second edit".utf8).write(to: source)

        _ = try await AsyncFileProviderMutationCoordinator(store: store, backend: LegacyAsyncFileProviderBackendAdapter(backend: memory))
            .modify(item: item, baseVersion: item.version.content, fields: [.contents], contents: source, options: [], context: context(item.itemIdentifier))

        XCTAssertEqual(try memory.content(identifier: item.itemIdentifier, expectedVersion: nil), Data("second edit".utf8))
        XCTAssertEqual(try store.operation(replayKey: "modify|stale-attempt")?.operation.state, "cancelled")
    }

    func testLocalOnlyMetadataChangesSkipTheServer() async throws {
        let (store, _) = try makeStore()
        let item = RemoteItem(remoteID: "remote-local-only", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "ro.txt", uri: "/ro.txt", kind: .file, contentType: "public.plain-text", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true, canWrite: false)
        try store.insertItem(item)
        let flaky = FlakyModifyBackend(memory: MemoryFileProviderBackend(items: [item]), failures: 0)
        let result = try await AsyncFileProviderMutationCoordinator(store: store, backend: LegacyAsyncFileProviderBackendAdapter(backend: flaky))
            .modify(item: item, baseVersion: item.version.content, fields: [.extendedAttributes, .tagData, .contentModificationDate], contents: nil, options: [], context: context(item.itemIdentifier))
        XCTAssertEqual(result.itemIdentifier, item.itemIdentifier)
        XCTAssertEqual(flaky.modifyCalls, 0)
        XCTAssertNil(try store.latestOperation(itemIdentifier: item.itemIdentifier))
    }

    // MARK: Resumable downloads

    func testInterruptedDownloadResumesWithRangeRequest() async throws {
        let payload = Data((0..<64 * 1024).map { UInt8($0 % 251) })
        let state = RangeDownloadURLProtocol.State(payload: payload, failAfter: 20_000)
        RangeDownloadURLProtocol.install(state)
        defer { RangeDownloadURLProtocol.clear() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeDownloadURLProtocol.self]
        let transport = RegisteredURLSessionTransport(session: URLSession(configuration: configuration))
        let partial = temporaryURL("download.partial")
        let request = URLRequest(url: URL(string: "https://storage.example/object")!)

        do {
            _ = try await transport.streamDownload(appendingTo: partial, resumeOffset: 0, request: request, itemIdentifier: NSFileProviderItemIdentifier("cri-download-1"), context: context("cri-download-1"))
            XCTFail("the injected connection loss must escape")
        } catch let failure as CoreFailure {
            XCTAssertEqual(failure.code, .network)
        }
        let received = PartialDownloadStore.size(of: partial)
        XCTAssertEqual(received, 20_000, "bytes received before the failure are kept")

        var resume = request
        resume.setValue("bytes=\(received)-", forHTTPHeaderField: "Range")
        let response = try await transport.streamDownload(appendingTo: partial, resumeOffset: received, request: resume, itemIdentifier: NSFileProviderItemIdentifier("cri-download-1"), context: context("cri-download-1"))
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(try Data(contentsOf: partial), payload)
        XCTAssertEqual(state.rangeHeaders, [nil, "bytes=20000-"])
    }

    func testServerIgnoringRangeRestartsThePartialFile() async throws {
        let payload = Data("complete object".utf8)
        let state = RangeDownloadURLProtocol.State(payload: payload, failAfter: nil, honorRange: false)
        RangeDownloadURLProtocol.install(state)
        defer { RangeDownloadURLProtocol.clear() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeDownloadURLProtocol.self]
        let transport = RegisteredURLSessionTransport(session: URLSession(configuration: configuration))
        let partial = temporaryURL("restart.partial")
        try Data("stale-prefix".utf8).write(to: partial)
        var request = URLRequest(url: URL(string: "https://storage.example/object")!)
        request.setValue("bytes=12-", forHTTPHeaderField: "Range")

        let response = try await transport.streamDownload(appendingTo: partial, resumeOffset: 12, request: request, itemIdentifier: NSFileProviderItemIdentifier("cri-download-2"), context: context("cri-download-2"))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(try Data(contentsOf: partial), payload)
    }

    // MARK: Domain cleanup

    func testEmptyRegistryNeverRemovesRegisteredLocations() {
        let system = [RegisteredDomainSnapshot(identifier: CloudreveIdentifier.domain(), displayName: "A")]
        XCTAssertTrue(OrphanedDomainCleanupReducer.orphanedIdentifiers(systemDomains: system, registryIdentifiers: []).isEmpty)
    }
}

/// Storage endpoint stub: optionally drops the connection after N bytes and
/// serves `Range: bytes=<start>-` requests with 206 Partial Content.
private final class RangeDownloadURLProtocol: URLProtocol {
    final class State: @unchecked Sendable {
        let payload: Data
        let failAfter: Int?
        let honorRange: Bool
        private let lock = NSLock()
        private var headers: [String?] = []
        private var failed = false

        init(payload: Data, failAfter: Int?, honorRange: Bool = true) {
            self.payload = payload
            self.failAfter = failAfter
            self.honorRange = honorRange
        }

        var rangeHeaders: [String?] { lock.lock(); defer { lock.unlock() }; return headers }

        func record(_ range: String?) -> Bool {
            lock.lock(); defer { lock.unlock() }
            headers.append(range)
            guard !failed, failAfter != nil else { return false }
            failed = true
            return true
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state: State?

    static func install(_ value: State) { lock.lock(); state = value; lock.unlock() }
    static func clear() { lock.lock(); state = nil; lock.unlock() }
    private static var current: State? { lock.lock(); defer { lock.unlock() }; return state }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "storage.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let state = Self.current, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let range = request.value(forHTTPHeaderField: "Range")
        let shouldFail = state.record(range)
        let total = state.payload.count
        if state.honorRange, let range, range.hasPrefix("bytes="), let start = Int(range.dropFirst("bytes=".count).dropLast()), start < total {
            let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: ["Content-Range": "bytes \(start)-\(total - 1)/\(total)", "Content-Length": String(total - start)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: state.payload.subdata(in: start..<total))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(total)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if shouldFail, let failAfter = state.failAfter {
            client?.urlProtocol(self, didLoad: state.payload.prefix(failAfter))
            // Let the received bytes reach the task delegate before the
            // connection drops; a real transfer streams long before failing.
            let client = self.client
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
            return
        }
        client?.urlProtocol(self, didLoad: state.payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Forwards to a memory backend, failing the first N content modifications
/// with a retryable network error.
private final class FlakyModifyBackend: FileProviderBackend, @unchecked Sendable {
    private let memory: MemoryFileProviderBackend
    private let lock = NSLock()
    private var remainingFailures: Int
    private(set) var modifyCalls = 0

    init(memory: MemoryFileProviderBackend, failures: Int) {
        self.memory = memory
        self.remainingFailures = failures
    }

    func item(identifier: String) throws -> RemoteItem? { try memory.item(identifier: identifier) }
    func children(parentIdentifier: String) throws -> [RemoteItem] { try memory.children(parentIdentifier: parentIdentifier) }
    func childrenPage(parentIdentifier: String, offset: Int, limit: Int) throws -> DirectoryPage { try memory.childrenPage(parentIdentifier: parentIdentifier, offset: offset, limit: limit) }
    func trashItems() throws -> [RemoteItem] { try memory.trashItems() }
    func content(identifier: String, expectedVersion: Data?) throws -> Data { try memory.content(identifier: identifier, expectedVersion: expectedVersion) }
    func create(template: RemoteItem, content: Data?, replayKey: String) throws -> RemoteItem { try memory.create(template: template, content: content, replayKey: replayKey) }
    func modify(item: RemoteItem, expectedVersion: Data?, changedFields: NSFileProviderItemFields, content: Data?, replayKey: String) throws -> RemoteItem {
        lock.lock()
        modifyCalls += 1
        let shouldFail = remainingFailures > 0
        if shouldFail { remainingFailures -= 1 }
        lock.unlock()
        if shouldFail { throw CoreFailure(code: .network, retryable: true) }
        return try memory.modify(item: item, expectedVersion: expectedVersion, changedFields: changedFields, content: content, replayKey: replayKey)
    }
    func trash(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { try memory.trash(item: item, expectedVersion: expectedVersion, replayKey: replayKey) }
    func restore(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { try memory.restore(item: item, expectedVersion: expectedVersion, replayKey: replayKey) }
    func delete(identifier: String, expectedVersion: Data?, recursive: Bool) throws { try memory.delete(identifier: identifier, expectedVersion: expectedVersion, recursive: recursive) }
}
