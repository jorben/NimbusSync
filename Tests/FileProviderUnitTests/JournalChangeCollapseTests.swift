import XCTest
import Foundation
import FileProvider
import CloudreveDomainKit
import CloudreveStoreBridge
@testable import CloudreveFileProviderKit

final class JournalChangeCollapseTests: XCTestCase {
    private let epoch = UUID()
    private let root = NSFileProviderItemIdentifier.rootContainer.rawValue

    /// Repro A: an item hidden and shown again inside one batch must be reported once, as
    /// visible; reporting update-then-delete would hide an item that is visible.
    func testViewRemovedThenViewAddedCollapsesToFinalVisibleState() throws {
        let item = try makeItem(identifier: "item-a", parent: root, path: "/f.txt")
        let changes = [
            try change(sequence: 10, item: item, old: root, new: root, kind: "view_removed"),
            try change(sequence: 11, item: item, old: root, new: root, kind: "view_added")
        ]

        let collapsed = collapsedJournalChanges(changes)

        XCTAssertEqual(collapsed.count, 1)
        XCTAssertEqual(collapsed.first?.kind, "view_added")
        XCTAssertEqual(collapsed.first?.sequence, 11)
        XCTAssertEqual(orderedJournalChanges(collapsed).map(\.kind), ["view_added"])
    }

    /// Repro B: `/f` moved to `/a/b/f` and back inside one batch must end at `/f` under the root,
    /// with the first old parent and the final new parent.
    func testMoveAndMoveBackCollapsesToFinalParentAndPayload() throws {
        let deep = try makeItem(identifier: "item-f", parent: "folder-b", path: "/a/b/f")
        let back = try makeItem(identifier: "item-f", parent: root, path: "/f")
        let changes = [
            try change(sequence: 20, item: deep, old: root, new: "folder-b", kind: "updated"),
            try change(sequence: 21, item: back, old: "folder-b", new: root, kind: "updated")
        ]

        let collapsed = collapsedJournalChanges(changes)

        XCTAssertEqual(collapsed.count, 1)
        let final = try XCTUnwrap(collapsed.first)
        XCTAssertEqual(final.sequence, 21)
        XCTAssertEqual(final.oldParentIdentifier, root)
        XCTAssertEqual(final.newParentIdentifier, root)
        XCTAssertEqual(try JSONDecoder().decode(RemoteItem.self, from: final.itemPayload).uri, back.uri)
    }

    /// The latest change wins even when the batch is not in sequence order.
    func testCollapseUsesHighestSequenceRegardlessOfInputOrder() throws {
        let item = try makeItem(identifier: "item-a", parent: root, path: "/f.txt")
        let changes = [
            try change(sequence: 31, item: item, old: "folder-x", new: root, kind: "view_added"),
            try change(sequence: 30, item: item, old: root, new: "folder-x", kind: "view_removed")
        ]

        let collapsed = collapsedJournalChanges(changes)

        XCTAssertEqual(collapsed.map(\.kind), ["view_added"])
        XCTAssertEqual(collapsed.first?.oldParentIdentifier, root)
        XCTAssertEqual(collapsed.first?.newParentIdentifier, root)
    }

    /// Distinct items are untouched and keep parent-before-child upserts and child-before-parent deletes.
    func testDistinctItemsKeepExistingOrdering() throws {
        let child = try makeItem(identifier: "child", parent: "folder-a", path: "/a/child.txt")
        let parent = try makeItem(identifier: "folder-a", parent: root, path: "/a", kind: .folder)
        let deletedChild = try makeItem(identifier: "gone-child", parent: "gone", path: "/gone/x.txt")
        let deletedParent = try makeItem(identifier: "gone", parent: root, path: "/gone", kind: .folder)
        let changes = [
            try change(sequence: 40, item: deletedParent, old: root, new: nil, kind: "deleted"),
            try change(sequence: 41, item: child, old: nil, new: "folder-a", kind: "created"),
            try change(sequence: 42, item: deletedChild, old: "gone", new: nil, kind: "deleted"),
            try change(sequence: 43, item: parent, old: nil, new: root, kind: "created")
        ]

        let collapsed = collapsedJournalChanges(changes)
        XCTAssertEqual(collapsed, changes)
        XCTAssertEqual(orderedJournalChanges(collapsed).map(\.itemIdentifier), ["folder-a", "child", "gone-child", "gone"])
    }

    private func makeItem(identifier: String, parent: String, path: String, kind: RemoteItemKind = .file) throws -> RemoteItem {
        RemoteItem(
            itemIdentifier: identifier,
            remoteID: "remote-\(identifier)",
            parentIdentifier: parent,
            name: String(path.split(separator: "/").last ?? ""),
            uri: try CloudreveRemoteURI.canonical(path, accountID: "account"),
            kind: kind,
            contentType: kind == .folder ? "public.folder" : "public.data",
            version: ItemVersion(content: Data(path.utf8), metadata: Data(path.utf8))
        )
    }

    private func change(sequence: Int64, item: RemoteItem, old: String?, new: String?, kind: String) throws -> JournalChange {
        JournalChange(sequence: sequence, epoch: epoch, itemIdentifier: item.itemIdentifier, oldParentIdentifier: old, newParentIdentifier: new, kind: kind, version: item.version.content, origin: "remote", providerVisible: true, itemPayload: try JSONEncoder().encode(item), itemVersion: item.version)
    }
}
