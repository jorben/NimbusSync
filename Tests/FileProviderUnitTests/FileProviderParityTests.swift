import XCTest
import Foundation
import FileProvider
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveFileProviderKit

final class FileProviderParityTests: XCTestCase {
    func testWorkingSetUsesOpaqueKeysetMembership() throws {
        let store = try SQLiteStateStore(url: temporaryURL("working-set"))
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let first = item(name: "a.txt")
        let second = item(name: "b.txt")
        try store.insertItem(first)
        try store.insertItem(second)
        try store.setMaterialized(second.itemIdentifier, materialized: true)
        let page = try store.workingSetItems(limit: 1)
        XCTAssertEqual(page.count, 1)
        let next = try store.workingSetItems(afterIdentifier: page[0].itemIdentifier, limit: 1)
        XCTAssertEqual(next.count, 1)
        XCTAssertNotEqual(next[0].itemIdentifier, page[0].itemIdentifier)
        XCTAssertEqual(Set(next.map(\.itemIdentifier)), Set([first.itemIdentifier, second.itemIdentifier]).subtracting([page[0].itemIdentifier]))
    }

    func testImmutableJournalPayloadSurvivesLiveProjectionUpdate() throws {
        let store = try SQLiteStateStore(url: temporaryURL("journal"))
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let domain = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: domain, displayName: "Parity", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "ref"))
        let original = item(name: "before.txt")
        let change = try store.commitProviderChange(item: original, oldParentIdentifier: nil, newParentIdentifier: original.parentIdentifier, kind: "created", origin: "test")
        var current = original
        current.name = "after.txt"
        try store.insertItem(current)
        let anchor = SyncAnchor(domainIdentifier: domain, scope: NSFileProviderItemIdentifier.rootContainer.rawValue, epoch: change.epoch, sequence: 0)
        let replay = try store.enumerateChanges(domainIdentifier: domain, scope: NSFileProviderItemIdentifier.rootContainer.rawValue, from: anchor)
        XCTAssertEqual(try JSONDecoder().decode(RemoteItem.self, from: XCTUnwrap(replay.changes.first?.itemPayload)), original)
    }

    func testRemoteIdentitySurvivesTombstoneAndReappearance() throws {
        let store = try SQLiteStateStore(url: temporaryURL("reappearance"))
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let stableIdentifier = CloudreveIdentifier.item()
        let original = RemoteItem(itemIdentifier: stableIdentifier, remoteID: "remote-reappears", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "old.txt", uri: "/old.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true)
        var tombstone = original
        tombstone.tombstone = true
        try store.insertItem(tombstone)

        let observed = RemoteItem(itemIdentifier: CloudreveIdentifier.item(), remoteID: original.remoteID, parentIdentifier: original.parentIdentifier, name: "new.txt", uri: "/new.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v2".utf8), metadata: Data("m2".utf8)), canRead: true)
        let reappeared = try store.upsertRemoteItem(observed)

        XCTAssertEqual(reappeared.itemIdentifier, stableIdentifier)
        XCTAssertFalse(try XCTUnwrap(store.item(identifier: stableIdentifier)).tombstone)
        XCTAssertEqual(try store.itemIdentifier(forRemoteID: "remote-reappears"), stableIdentifier)
    }

    func testRecursiveTombstonePublishesChildrenBeforeParent() throws {
        let store = try SQLiteStateStore(url: temporaryURL("recursive-delete"))
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let domain = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: domain, displayName: "Parity", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "ref"))
        let folder = item(name: "folder", kind: .folder, uri: "/folder")
        let child = item(name: "child", parent: folder.itemIdentifier, uri: "/folder/child")
        try store.insertItem(folder)
        try store.insertItem(child)
        try store.setMaterialized(folder.itemIdentifier, materialized: true)
        let operation = PendingOperation(replayKey: "recursive-delete", kind: "delete", itemIdentifier: folder.itemIdentifier)
        _ = try store.upsertOperation(operation)
        var tombstone = folder
        tombstone.tombstone = true
        try store.commitOperationWithItemAndChange(operationID: operation.operationID, state: "committed", item: tombstone, oldParentIdentifier: folder.parentIdentifier, newParentIdentifier: nil, kind: "deleted", origin: "test", recursive: true)

        let anchor = SyncAnchor(domainIdentifier: domain, scope: NSFileProviderItemIdentifier.workingSet.rawValue, epoch: try store.syncState().epoch, sequence: 0)
        let changes = try store.enumerateChanges(domainIdentifier: domain, scope: anchor.scope, from: anchor).changes
        XCTAssertEqual(changes.filter { $0.kind == "deleted" }.map(\.itemIdentifier), [child.itemIdentifier, folder.itemIdentifier])
        XCTAssertTrue(try XCTUnwrap(store.item(identifier: child.itemIdentifier)).tombstone)
        XCTAssertTrue(try XCTUnwrap(store.item(identifier: folder.itemIdentifier)).tombstone)
    }

    func testWorkingSetReplayUsesJournalAudienceAfterEviction() throws {
        let store = try SQLiteStateStore(url: temporaryURL("journal-audience"))
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let domainID = CloudreveIdentifier.domain()
        let folder = item(name: "folder", kind: .folder, uri: "/folder")
        let child = item(name: "child.txt", parent: folder.itemIdentifier, uri: "/folder/child.txt")
        try store.insertItem(folder)
        try store.insertItem(child)
        try store.setMaterialized(folder.itemIdentifier, materialized: true)
        let before = try store.currentAnchor(domainIdentifier: domainID, scope: NSFileProviderItemIdentifier.workingSet.rawValue)

        _ = try store.commitProviderChange(
            item: child,
            oldParentIdentifier: child.parentIdentifier,
            newParentIdentifier: child.parentIdentifier,
            kind: "modified",
            origin: "test"
        )
        try store.setMaterialized(folder.itemIdentifier, materialized: false)

        let replay = try store.enumerateChanges(
            domainIdentifier: domainID,
            scope: NSFileProviderItemIdentifier.workingSet.rawValue,
            from: before
        )
        XCTAssertEqual(replay.changes.map(\.itemIdentifier), [child.itemIdentifier])
        XCTAssertTrue(replay.changes[0].providerVisible)
    }

    func testRootScopeFiltersPriorCanonicalItemsWithoutRemoteDeletion() throws {
        let store = try SQLiteStateStore(url: temporaryURL("root-scope-filter"))
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let domainID = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/new-root")
        try store.registerDomain(DomainDescriptor(identifier: domainID, displayName: "Parity", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "ref"))
        let insideURI = try CloudreveRemoteURI.canonical("/new-root/inside.txt", accountID: "account")
        let outsideURI = try CloudreveRemoteURI.canonical("/old-root/outside.txt", accountID: "account")
        let inside = RemoteItem(remoteID: "inside", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "inside.txt", uri: insideURI, kind: .file, contentType: "public.data", version: ItemVersion(content: Data("inside".utf8), metadata: Data("inside".utf8)), canRead: true)
        let outside = RemoteItem(remoteID: "outside", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "outside.txt", uri: outsideURI, kind: .file, contentType: "public.data", version: ItemVersion(content: Data("outside".utf8), metadata: Data("outside".utf8)), canRead: true)
        try store.insertItems([inside, outside])

        XCTAssertEqual(try store.listChildren(parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue).map(\.itemIdentifier), [inside.itemIdentifier])
        XCTAssertEqual(try store.workingSetItems(limit: 10).map(\.itemIdentifier), [inside.itemIdentifier])
        XCTAssertEqual(try store.item(identifier: outside.itemIdentifier)?.remoteID, outside.remoteID)
    }

    func testSystemSetClaimFencesStaleOwner() throws {
        let store = try SQLiteStateStore(url: temporaryURL("system-set"))
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let first = try XCTUnwrap(store.claimSystemSet(setKind: "pending", ownerID: UUID(), staleAfter: 60))
        XCTAssertThrowsError(try store.setSystemSetCursor(claim: SystemSetClaim(setKind: "pending", generation: first.generation, ownerID: UUID(), domainVersion: nil), cursor: Data("stale".utf8))) { error in
            XCTAssertEqual(error as? StoreBridgeError, .generationFenced)
        }
        try store.releaseSystemSetClaim(claim: first)
    }

    func testSystemSetClaimFencesChangedDomainVersion() throws {
        let store = try SQLiteStateStore(url: temporaryURL("system-set-version"))
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let domain = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: domain, displayName: "Parity", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "ref"))
        let version = try store.currentAnchor(domainIdentifier: domain, scope: NSFileProviderItemIdentifier.workingSet.rawValue).encoded()
        let claim = try XCTUnwrap(store.claimSystemSet(setKind: "pending", ownerID: UUID(), domainVersion: version))
        _ = try store.rotateSyncEpoch(reason: "test")
        let nextVersion = try store.currentAnchor(domainIdentifier: domain, scope: NSFileProviderItemIdentifier.workingSet.rawValue).encoded()
        _ = try XCTUnwrap(store.claimSystemSet(setKind: "pending", ownerID: UUID(), domainVersion: nextVersion))
        XCTAssertThrowsError(try store.setSystemSetCursor(claim: claim, cursor: Data("stale".utf8))) { error in
            XCTAssertEqual(error as? StoreBridgeError, .generationFenced)
        }
    }

    func testDirectorySnapshotReadFiltersExcludedItem() throws {
        let store = try SQLiteStateStore(url: temporaryURL("snapshot-exclusion"))
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let domain = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: domain, displayName: "Parity", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "ref"))
        let visible = item(name: "visible.txt")
        let hidden = item(name: "hidden.tmp")
        try store.insertItem(visible)
        try store.insertItem(hidden)
        let rules = ExclusionRuleSnapshot(revision: 1, rules: ["*.tmp"])
        try store.setPreference(key: "exclusion.rules.\(domain)", value: String(data: try JSONEncoder().encode(rules), encoding: .utf8)!)
        let snapshot = try store.beginDirectorySnapshot(domainIdentifier: domain, parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue)
        try store.appendDirectorySnapshotItems(snapshotID: snapshot.snapshotID, items: [visible, hidden])
        try store.publishDirectorySnapshot(snapshotID: snapshot.snapshotID)

        let page = try store.directorySnapshotPage(domainIdentifier: domain, parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, generation: snapshot.generation, snapshotID: snapshot.snapshotID, offset: 0, limit: 10)
        XCTAssertEqual(page.items.map(\.itemIdentifier), [visible.itemIdentifier])
        XCTAssertTrue(try store.localItemState(identifier: hidden.itemIdentifier).viewExcluded)
        XCTAssertEqual(try XCTUnwrap(store.item(identifier: hidden.itemIdentifier)).remoteID, hidden.remoteID)
    }

    func testBatchProviderChangeDeduplicationIncludesViewState() throws {
        let store = try SQLiteStateStore(url: temporaryURL("batch-view-state"))
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let item = item(name: "hidden.tmp")
        try store.insertItem(item)
        let input = ProviderChangeInput(item: item, oldParentIdentifier: item.parentIdentifier, newParentIdentifier: item.parentIdentifier, kind: "view_removed", origin: "test")

        let first = try store.commitProviderChanges([input])
        XCTAssertEqual(first.map(\.kind), ["view_removed"])
        XCTAssertTrue(try store.localItemState(identifier: item.itemIdentifier).viewExcluded)
        XCTAssertTrue(try store.commitProviderChanges([input]).isEmpty)
    }

    func testSpecialSymlinkPolicyFailsClosed() throws {
        let source = temporaryURL("regular")
        let link = temporaryURL("symlink")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: link)
        }
        try Data("content".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertEqual(try SpecialFilePolicy.decision(for: link), .excluded)
    }

    private var storeURL = URL(fileURLWithPath: "/dev/null")

    private func temporaryURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-file-provider-\(name)-\(UUID().uuidString).sqlite3")
        storeURL = url
        return url
    }

    private func item(name: String) -> RemoteItem {
        item(name: name, parent: NSFileProviderItemIdentifier.rootContainer.rawValue, uri: "/\(name)")
    }

    private func item(name: String, kind: RemoteItemKind = .file, parent: String = NSFileProviderItemIdentifier.rootContainer.rawValue, uri: String) -> RemoteItem {
        RemoteItem(remoteID: "remote-\(name)-\(UUID().uuidString)", parentIdentifier: parent, name: name, uri: uri, kind: kind, contentType: kind == .folder ? "public.folder" : "public.data", version: ItemVersion(content: Data(name.utf8), metadata: Data(name.utf8)), canRead: true)
    }
}
