import Foundation
import UniformTypeIdentifiers

/// Wire fields shared by every Cloudreve v4 file DTO (`file`, `file/info`,
/// trash listing and SSE enrichment). Each module keeps its private Decodable
/// type and converts into this value before projection.
public struct CloudreveFileFields: Sendable, Equatable {
    public let type: Int
    public let id: String
    public let name: String
    public let size: Int64?
    public let permission: String?
    public let capability: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let primaryEntity: String?
    /// Public metadata (`sys:*`, `tag:*`, …) as the listing returns it.
    public let metadata: [String: String]

    public init(type: Int, id: String, name: String, size: Int64?, permission: String?, capability: String?, createdAt: String?, updatedAt: String?, primaryEntity: String?, metadata: [String: String] = [:]) {
        self.type = type; self.id = id; self.name = name; self.size = size; self.permission = permission
        self.capability = capability; self.createdAt = createdAt; self.updatedAt = updatedAt; self.primaryEntity = primaryEntity
        self.metadata = metadata
    }

    /// Set on a file while an upload session targets it (Cloudreve's own explorer shows such
    /// files as "uploading").
    public static let uploadSessionMetadataKey = "sys:upload_session_id"

    /// A trashed file's original location. Its `path` names the trash filesystem instead
    /// (`cloudreve://trash/…`), which the official explorer also never shows.
    public static let restoreURIMetadataKey = "sys:restore_uri"

    /// A file an upload session is still writing. For a new path that is a 0-byte placeholder
    /// with no content, created the moment the session opens — by this client or any other.
    public var hasActiveUploadSession: Bool {
        type == 0 && metadata[Self.uploadSessionMetadataKey] != nil
    }
}

/// Cloudreve file metadata. Values are strings on the wire; anything else is dropped instead of
/// failing the whole listing.
public struct CloudreveFileMetadata: Decodable, Sendable, Equatable {
    public let values: [String: String]

    public init(_ values: [String: String] = [:]) { self.values = values }

    public init(from decoder: Decoder) throws {
        var values: [String: String] = [:]
        if let container = try? decoder.container(keyedBy: DynamicKey.self) {
            for key in container.allKeys {
                if let value = try? container.decode(String.self, forKey: key) { values[key.stringValue] = value }
            }
        }
        self.values = values
    }

    private struct DynamicKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

/// The single Cloudreve → `RemoteItem` projection. Listing, SSE enrichment
/// and reconciliation previously carried four diverging copies, so the same
/// object flipped capabilities (and therefore its metadata version) depending
/// on which path last observed it.
public enum CloudreveItemMapper {
    public static func kind(forType type: Int) -> RemoteItemKind {
        switch type {
        case 0: return .file
        case 1: return .folder
        default: return .unsupported
        }
    }

    public static func item(from file: CloudreveFileFields, normalizedURI: String, parentIdentifier: String, itemIdentifier: String, capabilities: CapabilitySnapshot) -> RemoteItem {
        let kind = kind(forType: file.type)
        let contentVersion = RemoteContentVersionPolicy.resolve(primaryEntity: file.primaryEntity, stableEntityID: file.id)
        let readable = file.permission.map { $0.contains("r") } ?? true
        let remoteWritable = file.capability?.contains("w") ?? false
        let remoteDeletable = file.capability?.contains("d") ?? false
        let metadataWritable = remoteWritable && capabilities.allowsMetadataMove
        let contentWritable = remoteWritable && capabilities.allowsContentWrite
        let writable: Bool
        switch kind {
        case .folder: writable = metadataWritable
        case .file: writable = contentVersion.reliable && (contentWritable || metadataWritable)
        case .symlink, .unsupported: writable = false
        }
        return RemoteItem(
            itemIdentifier: itemIdentifier,
            remoteID: file.id,
            parentIdentifier: parentIdentifier,
            name: file.name,
            uri: normalizedURI,
            kind: kind,
            contentType: contentType(kind: kind, name: file.name),
            size: max(0, file.size ?? 0),
            remoteVersion: file.primaryEntity,
            version: ItemVersion(
                content: VersionHasher.content(primaryEntity: contentVersion.value),
                metadata: VersionHasher.metadata(parent: parentIdentifier, name: file.name, kind: kind, permissionBits: readable ? 1 : 0, revision: file.updatedAt)
            ),
            creationDate: parseDate(file.createdAt),
            contentModificationDate: parseDate(file.updatedAt),
            canRead: readable && kind != .unsupported,
            canWrite: readable && writable,
            canAddChildren: readable && kind == .folder && remoteWritable && capabilities.allowsCreate,
            canTrash: readable && remoteWritable && remoteDeletable && capabilities.canTrash,
            canDelete: readable && remoteWritable && remoteDeletable && capabilities.canPurge
        )
    }

    public static func contentType(kind: RemoteItemKind, name: String) -> String {
        switch kind {
        case .folder:
            return UTType.folder.identifier
        case .symlink:
            return UTType.symbolicLink.identifier
        case .file:
            let ext = (name as NSString).pathExtension
            guard !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic else { return UTType.data.identifier }
            return type.identifier
        case .unsupported:
            return UTType.data.identifier
        }
    }

    /// Cloudreve emits RFC 3339 timestamps with and without fractional
    /// seconds; the default ISO8601 formatter silently rejects the former.
    public static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
