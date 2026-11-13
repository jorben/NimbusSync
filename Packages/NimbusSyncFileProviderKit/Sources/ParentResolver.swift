import Foundation
import FileProvider
import CloudreveDomainKit
import CloudreveStoreBridge

public enum ParentResolutionError: Error, Equatable, Sendable {
    case missing
    case outsideScope
    case invalidIdentifier
    case retryable
}

public final class ParentResolver: @unchecked Sendable {
    private let store: SQLiteStateStore
    private let rootURI: String
    private let accountID: String
    private let rootIdentifier: String
    private let maxDepth: Int

    public init(store: SQLiteStateStore, rootURI: String, accountID: String, rootIdentifier: String, maxDepth: Int = 32) {
        self.store = store
        self.rootURI = rootURI
        self.accountID = accountID
        self.rootIdentifier = rootIdentifier
        self.maxDepth = max(1, maxDepth)
    }

    public func resolve(
        parentIdentifier: String,
        knownURI: String? = nil,
        hydrate: (() throws -> RemoteItem?)? = nil,
        hydrateParent: ((String) throws -> RemoteItem?)? = nil,
        hydrateParentWithIdentifier: ((String, String) throws -> RemoteItem?)? = nil
    ) throws -> RemoteItem {
        if parentIdentifier == NSFileProviderItemIdentifier.rootContainer.rawValue {
            return RemoteItem(itemIdentifier: parentIdentifier, remoteID: rootIdentifier, name: "", uri: rootURI, kind: .folder, contentType: "public.folder", version: ItemVersion(content: Data("root".utf8), metadata: Data(rootURI.utf8)), canRead: true)
        }
        guard CloudreveIdentifier.validate(parentIdentifier, prefix: CloudreveIdentifier.itemPrefix) else {
            throw ParentResolutionError.invalidIdentifier
        }
        if let item = try store.item(identifier: parentIdentifier) {
            try validateItem(item)
            try validateAncestorChain(item, hydrateParent: hydrateParent, hydrateParentWithIdentifier: hydrateParentWithIdentifier)
            return item
        }
        if let knownURI {
            let canonicalKnownURI: String
            do { canonicalKnownURI = try CloudreveRemoteURI.canonical(knownURI, accountID: accountID) }
            catch { throw ParentResolutionError.outsideScope }
            guard CloudreveRemoteURI.isWithin(canonicalKnownURI, root: rootURI) else { throw ParentResolutionError.outsideScope }
            if let identifier = try store.itemIdentifier(forRemoteURI: canonicalKnownURI), identifier == parentIdentifier, let item = try store.item(identifier: identifier) {
                try validateItem(item)
                try validateAncestorChain(item, hydrateParent: hydrateParent, hydrateParentWithIdentifier: hydrateParentWithIdentifier)
                return item
            }
        }
        guard let hydrate, let item = try hydrate() else { throw ParentResolutionError.retryable }
        guard item.itemIdentifier == parentIdentifier else { throw ParentResolutionError.missing }
        try validateItem(item)
        try store.insertItem(item)
        try validateAncestorChain(item, hydrateParent: hydrateParent, hydrateParentWithIdentifier: hydrateParentWithIdentifier)
        return item
    }

    private func validateItem(_ item: RemoteItem) throws {
        guard item.kind == .folder else { throw ParentResolutionError.missing }
        guard let canonical = try? CloudreveRemoteURI.canonical(item.uri, accountID: accountID), CloudreveRemoteURI.isWithin(canonical, root: rootURI) else {
            throw ParentResolutionError.outsideScope
        }
    }

    private func validateAncestorChain(
        _ item: RemoteItem,
        hydrateParent: ((String) throws -> RemoteItem?)?,
        hydrateParentWithIdentifier: ((String, String) throws -> RemoteItem?)?
    ) throws {
        var current = item
        var visited = Set<String>([item.itemIdentifier])
        for _ in 0..<maxDepth {
            guard let parent = current.parentIdentifier else { return }
            if parent == NSFileProviderItemIdentifier.rootContainer.rawValue { return }
            guard CloudreveIdentifier.validate(parent, prefix: CloudreveIdentifier.itemPrefix) else { throw ParentResolutionError.invalidIdentifier }
            guard visited.insert(parent).inserted else { throw ParentResolutionError.retryable }
            let parentItem: RemoteItem
            if let stored = try store.item(identifier: parent) {
                parentItem = stored
            } else {
                guard let parentURI = CloudreveRemoteURI.parent(current.uri) else {
                    throw ParentResolutionError.retryable
                }
                let hydrated: RemoteItem?
                if let hydrateParentWithIdentifier {
                    hydrated = try hydrateParentWithIdentifier(parentURI, parent)
                } else if let hydrateParent {
                    hydrated = try hydrateParent(parentURI)
                } else {
                    hydrated = nil
                }
                guard let hydrated, hydrated.itemIdentifier == parent else {
                    throw ParentResolutionError.retryable
                }
                try validateItem(hydrated)
                try store.insertItem(hydrated)
                parentItem = hydrated
            }
            try validateItem(parentItem)
            current = parentItem
        }
        throw ParentResolutionError.retryable
    }
}
