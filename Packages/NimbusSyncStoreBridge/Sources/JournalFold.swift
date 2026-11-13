import Foundation
import CloudreveDomainKit

public struct ProviderChangeInput: Sendable, Equatable {
    public let item: RemoteItem
    public let oldParentIdentifier: String?
    public let newParentIdentifier: String?
    public let kind: String
    public let origin: String

    public init(item: RemoteItem, oldParentIdentifier: String?, newParentIdentifier: String?, kind: String, origin: String) {
        self.item = item
        self.oldParentIdentifier = oldParentIdentifier
        self.newParentIdentifier = newParentIdentifier
        self.kind = kind
        self.origin = origin
    }
}

/// Folds one complete producer result before allocating global sequence
/// numbers. It keeps the first old parent and the final new parent for moves,
/// drops a create/delete for an identity that never reached the server, and
/// always leaves delete after all upserts at equal depth.
public enum JournalChangeFold {
    public static func fold(_ inputs: [ProviderChangeInput]) -> [ProviderChangeInput] {
        var folded: [String: ProviderChangeInput] = [:]
        var order: [String] = []
        for input in inputs {
            let identifier = input.item.itemIdentifier
            guard let existing = folded[identifier] else {
                folded[identifier] = input
                order.append(identifier)
                continue
            }

            if isViewRemoval(input) {
                folded[identifier] = ProviderChangeInput(
                    item: input.item,
                    oldParentIdentifier: existing.oldParentIdentifier ?? existing.item.parentIdentifier,
                    newParentIdentifier: input.newParentIdentifier ?? input.item.parentIdentifier,
                    kind: "view_removed",
                    origin: input.origin
                )
                continue
            }

            if isDelete(input) {
                if isCreate(existing) && existing.item.remoteID == nil {
                    folded.removeValue(forKey: identifier)
                    order.removeAll { $0 == identifier }
                    continue
                }
                var tombstone = input.item
                tombstone.tombstone = true
                folded[identifier] = ProviderChangeInput(
                    item: tombstone,
                    oldParentIdentifier: existing.oldParentIdentifier ?? existing.item.parentIdentifier,
                    newParentIdentifier: nil,
                    kind: "deleted",
                    origin: input.origin
                )
                continue
            }

            let firstOldParent = existing.oldParentIdentifier ?? existing.item.parentIdentifier
            folded[identifier] = ProviderChangeInput(
                item: input.item,
                oldParentIdentifier: firstOldParent,
                newParentIdentifier: input.newParentIdentifier ?? input.item.parentIdentifier,
                kind: isCreate(existing) ? existing.kind : input.kind,
                origin: input.origin
            )
        }

        let values = order.compactMap { folded[$0] }
        return values.sorted { left, right in
            let leftDelete = isDelete(left)
            let rightDelete = isDelete(right)
            if leftDelete != rightDelete { return !leftDelete }
            let leftDepth = pathDepth(left.item.uri)
            let rightDepth = pathDepth(right.item.uri)
            if leftDepth != rightDepth { return leftDelete ? leftDepth > rightDepth : leftDepth < rightDepth }
            return left.item.itemIdentifier < right.item.itemIdentifier
        }
    }

    private static func isViewRemoval(_ input: ProviderChangeInput) -> Bool {
        input.kind.lowercased() == "view_removed"
    }

    private static func isDelete(_ input: ProviderChangeInput) -> Bool {
        ["delete", "deleted"].contains(input.kind.lowercased()) || input.item.tombstone
    }

    private static func isCreate(_ input: ProviderChangeInput) -> Bool {
        ["create", "created"].contains(input.kind.lowercased())
    }

    private static func pathDepth(_ uri: String) -> Int {
        uri.split(separator: "/").count
    }
}
