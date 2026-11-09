import Foundation
import FileProvider
import CryptoKit

public enum CloudreveIdentifierError: Error, Equatable {
    case invalid(prefix: String)
    case sensitiveValue
}

public enum CloudreveIdentifier {
    public static let domainPrefix = "crd"
    public static let itemPrefix = "cri"

    public static func domain() -> String { "\(domainPrefix)-\(UUID().uuidString.lowercased())" }
    public static func item() -> String { "\(itemPrefix)-\(UUID().uuidString.lowercased())" }

    public static func item(forTemplate templateIdentifier: String) -> String {
        let digest = SHA256.hash(data: Data(templateIdentifier.utf8))
        let bytes = Array(digest.prefix(16))
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let uuid = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return "\(itemPrefix)-\(uuid)"
    }

    public static func validate(_ value: String, prefix: String) -> Bool {
        let expected = "\(prefix)-"
        guard value.hasPrefix(expected), value.count == expected.count + 36 else { return false }
        guard !value.contains("/"), !value.contains(":"), !value.contains("@") else { return false }
        return UUID(uuidString: String(value.dropFirst(expected.count))) != nil
    }
}

public struct RemoteScope: Codable, Hashable, Sendable {
    public let origin: String
    public let accountID: String
    public let rootURI: String

    public init(origin: String, accountID: String, rootURI: String) throws {
        guard !accountID.isEmpty, !accountID.contains(where: { $0 == "\0" || $0.isWhitespace }), var components = URLComponents(string: origin), components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty, components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
            throw CloudreveIdentifierError.sensitiveValue
        }
        components.scheme = "https"
        components.host = host.lowercased()
        if components.port == 443 { components.port = nil }
        guard let canonicalOrigin = components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { throw CloudreveIdentifierError.sensitiveValue }
        self.origin = canonicalOrigin
        self.accountID = accountID
        self.rootURI = try CloudreveRemoteURI.canonical(rootURI, accountID: accountID)
    }

    public var key: String { "\(origin)\u{0}\(accountID)\u{0}\(rootURI)" }

    public func overlaps(_ other: RemoteScope) -> Bool {
        guard origin == other.origin, accountID == other.accountID else { return false }
        return CloudreveRemoteURI.overlaps(rootURI, other.rootURI)
    }
}

public enum CloudreveRemoteURI {
    public static func canonical(_ rawValue: String, accountID: String) throws -> String {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("cloudreve://") {
            guard var components = URLComponents(string: raw), let host = components.host, host.lowercased() == "my", components.password == nil, components.query == nil, components.fragment == nil else { throw CloudreveIdentifierError.sensitiveValue }
            let path = try normalizedPath(components.path)
            components.scheme = "cloudreve"
            components.host = host.lowercased()
            components.port = nil
            if components.user == nil && components.host == "my" { components.user = accountID }
            guard components.user == nil || components.user == accountID else { throw CloudreveIdentifierError.sensitiveValue }
            components.path = path
            guard let value = components.string else { throw CloudreveIdentifierError.sensitiveValue }
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let path = try normalizedPath(raw)
        var components = URLComponents()
        components.scheme = "cloudreve"
        components.user = accountID
        components.host = "my"
        components.path = path == "/" ? "" : path
        guard let value = components.string else { throw CloudreveIdentifierError.sensitiveValue }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public static func path(_ value: String) -> String? {
        if value.hasPrefix("cloudreve://"), let components = URLComponents(string: value) { return try? normalizedPath(components.path) }
        return try? normalizedPath(value)
    }

    /// Redacted structural description of a remote URI for diagnostics: how
    /// it parses and which ASCII punctuation it carries (raw and decoded).
    /// Never includes names, path segments, account IDs or hosts.
    public static func diagnosticShape(_ rawValue: String) -> String {
        func punctuation(_ value: String) -> String {
            let scalars = Set(value.unicodeScalars.filter { $0.isASCII && !CharacterSet.alphanumerics.contains($0) && $0 != "/" }.map(Character.init))
            return String(scalars.sorted())
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if trimmed != rawValue { parts.append("edge_whitespace") }
        if !trimmed.hasPrefix("cloudreve://") { parts.append("bare_path") }
        if let components = URLComponents(string: trimmed) {
            if components.query != nil { parts.append("query") }
            if components.fragment != nil { parts.append("fragment") }
            if components.user != nil { parts.append("user") }
            if components.password != nil { parts.append("password") }
            if let host = components.host?.lowercased() { parts.append(["my", "trash", "shared_with_me"].contains(host) ? "host=\(host)" : "host=other") }
            parts.append("decoded=[\(punctuation(components.path))]")
        } else {
            parts.append("unparsable")
        }
        parts.append("raw=[\(punctuation(trimmed))]")
        if trimmed.unicodeScalars.contains(where: { !$0.isASCII }) { parts.append("non_ascii") }
        return parts.joined(separator: " ")
    }

    public static func append(_ parent: String, name: String) throws -> String {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { throw CloudreveIdentifierError.sensitiveValue }
        guard var components = URLComponents(string: parent), components.scheme == "cloudreve" else { throw CloudreveIdentifierError.sensitiveValue }
        let parentPath = try normalizedPath(components.path)
        components.path = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
        guard let result = components.string else { throw CloudreveIdentifierError.sensitiveValue }
        return result
    }

    public static func parent(_ value: String) -> String? {
        guard var components = URLComponents(string: value), components.scheme == "cloudreve", let path = try? normalizedPath(components.path) else { return nil }
        let segments = path.split(separator: "/")
        components.path = segments.count <= 1 ? "/" : "/" + segments.dropLast().joined(separator: "/")
        if components.path == "/" { components.path = "" }
        return components.string
    }

    public static func overlaps(_ left: String, _ right: String) -> Bool {
        guard let leftComponents = URLComponents(string: left), let rightComponents = URLComponents(string: right), leftComponents.scheme == "cloudreve", rightComponents.scheme == "cloudreve", leftComponents.host?.lowercased() == rightComponents.host?.lowercased(), leftComponents.user == rightComponents.user, let leftPath = path(left), let rightPath = path(right) else { return false }
        return leftPath == rightPath || leftPath == "/" || rightPath == "/" || leftPath.hasPrefix(rightPath + "/") || rightPath.hasPrefix(leftPath + "/")
    }

    public static func isWithin(_ value: String, root: String) -> Bool {
        guard let valueComponents = URLComponents(string: value), let rootComponents = URLComponents(string: root), valueComponents.scheme == rootComponents.scheme, valueComponents.host?.lowercased() == rootComponents.host?.lowercased(), valueComponents.user == rootComponents.user, let valuePath = path(value), let rootPath = path(root) else { return false }
        return rootPath == "/" || valuePath == rootPath || valuePath.hasPrefix(rootPath + "/")
    }

    public static func relativePath(_ value: String, root: String) -> String? {
        guard isWithin(value, root: root), let valuePath = path(value), let rootPath = path(root) else { return nil }
        guard rootPath != "/" else { return valuePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        return String(valuePath.dropFirst(rootPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private static func normalizedPath(_ rawPath: String) throws -> String {
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.split(separator: "/").contains(where: { $0 == ".." || $0.contains("\0") }) else { throw CloudreveIdentifierError.sensitiveValue }
        let parts = normalized.split(separator: "/").filter { !$0.isEmpty && $0 != "." }
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
    }
}

public enum RemoteItemKind: String, Codable, Sendable {
    case file
    case folder
    case symlink
    case unsupported
}

public struct CapabilitySnapshot: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case verified, unsupported, unverified }
    public struct Provider: Codable, Equatable, Sendable {
        public let name: String
        public let read: State
        public let write: State
        public let resumable: State
        public let zeroByte: State
        public let crypto: State
        public init(name: String, read: State, write: State, resumable: State, zeroByte: State, crypto: State) {
            self.name = name; self.read = read; self.write = write; self.resumable = resumable; self.zeroByte = zeroByte; self.crypto = crypto
        }
    }

    public struct OperationCapabilities: Codable, Equatable, Sendable {
        public var collisionSafeCreate: State
        public var conditionalModify: State
        public var metadataMove: State
        public var trash: State
        public var purge: State
        public var zeroByte: State
        public var resumable: State
        public var nativeConflictCopy: State
        public var fallbackConflict: State

        private enum CodingKeys: String, CodingKey {
            case collisionSafeCreate, conditionalModify, metadataMove, trash, purge, zeroByte, resumable, nativeConflictCopy, fallbackConflict
        }

        public init(
            collisionSafeCreate: State = .unsupported,
            conditionalModify: State = .unsupported,
            metadataMove: State = .unsupported,
            trash: State = .unsupported,
            purge: State = .unsupported,
            zeroByte: State = .unsupported,
            resumable: State = .unsupported,
            nativeConflictCopy: State = .unsupported,
            fallbackConflict: State = .unsupported
        ) {
            self.collisionSafeCreate = collisionSafeCreate
            self.conditionalModify = conditionalModify
            self.metadataMove = metadataMove
            self.trash = trash
            self.purge = purge
            self.zeroByte = zeroByte
            self.resumable = resumable
            self.nativeConflictCopy = nativeConflictCopy
            self.fallbackConflict = fallbackConflict
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                collisionSafeCreate: try container.decodeIfPresent(State.self, forKey: .collisionSafeCreate) ?? .unsupported,
                conditionalModify: try container.decodeIfPresent(State.self, forKey: .conditionalModify) ?? .unsupported,
                metadataMove: try container.decodeIfPresent(State.self, forKey: .metadataMove) ?? .unsupported,
                trash: try container.decodeIfPresent(State.self, forKey: .trash) ?? .unsupported,
                purge: try container.decodeIfPresent(State.self, forKey: .purge) ?? .unsupported,
                zeroByte: try container.decodeIfPresent(State.self, forKey: .zeroByte) ?? .unsupported,
                resumable: try container.decodeIfPresent(State.self, forKey: .resumable) ?? .unsupported,
                nativeConflictCopy: try container.decodeIfPresent(State.self, forKey: .nativeConflictCopy) ?? .unsupported,
                fallbackConflict: try container.decodeIfPresent(State.self, forKey: .fallbackConflict) ?? .unsupported
            )
        }
    }

    public var revision: UInt64
    public var serverVersion: String?
    public var stableItemIdentity: State
    public var stableRootIdentity: State
    public var completePagination: State
    public var cursorPagination: State
    public var snapshotSafePagination: State
    public var conditionalContentWrite: State
    public var conditionalMetadataMutation: State
    public var idempotentCreate: State
    public var contentVersionSemantics: State
    public var resumableUploadProviders: [String]
    public var uploadCompletionQueryableProviders: [String]
    public var zeroByteWriteProviders: [String]
    public var resolvedUploadPolicyKinds: [String]
    public var deleteSemantics: State
    public var trashRestore: State
    public var sse: State
    public var sseResume: State
    public var refreshRotationSemantics: State
    public var thumbnail: State
    public var providers: [Provider]
    public var operations: OperationCapabilities

    public init(revision: UInt64 = 0, serverVersion: String? = nil, stableItemIdentity: State = .unverified, stableRootIdentity: State = .unverified, completePagination: State = .unverified, cursorPagination: State = .unverified, snapshotSafePagination: State = .unverified, conditionalContentWrite: State = .unsupported, conditionalMetadataMutation: State = .unverified, idempotentCreate: State = .unsupported, contentVersionSemantics: State = .unverified, resumableUploadProviders: [String] = [], uploadCompletionQueryableProviders: [String] = [], zeroByteWriteProviders: [String] = [], resolvedUploadPolicyKinds: [String] = [], deleteSemantics: State = .unsupported, trashRestore: State = .unsupported, sse: State = .unverified, sseResume: State? = nil, refreshRotationSemantics: State = .unverified, thumbnail: State = .unverified, providers: [Provider] = [], operations: OperationCapabilities? = nil) {
        self.revision = revision; self.serverVersion = serverVersion; self.stableItemIdentity = stableItemIdentity; self.stableRootIdentity = stableRootIdentity; self.completePagination = completePagination; self.cursorPagination = cursorPagination; self.snapshotSafePagination = snapshotSafePagination; self.conditionalContentWrite = conditionalContentWrite; self.conditionalMetadataMutation = conditionalMetadataMutation; self.idempotentCreate = idempotentCreate; self.contentVersionSemantics = contentVersionSemantics; self.resumableUploadProviders = resumableUploadProviders; self.uploadCompletionQueryableProviders = uploadCompletionQueryableProviders; self.zeroByteWriteProviders = zeroByteWriteProviders; self.resolvedUploadPolicyKinds = resolvedUploadPolicyKinds; self.deleteSemantics = deleteSemantics; self.trashRestore = trashRestore; self.sse = sse; self.sseResume = sseResume ?? sse; self.refreshRotationSemantics = refreshRotationSemantics; self.thumbnail = thumbnail; self.providers = providers
        self.operations = operations ?? OperationCapabilities(collisionSafeCreate: idempotentCreate, conditionalModify: conditionalContentWrite, metadataMove: .unverified, trash: trashRestore, purge: trashRestore, zeroByte: .unverified, resumable: .unverified, nativeConflictCopy: .unverified, fallbackConflict: .unverified)
    }

    private enum CodingKeys: String, CodingKey {
        case revision, serverVersion, stableItemIdentity, stableRootIdentity, completePagination, cursorPagination, snapshotSafePagination, conditionalContentWrite, conditionalMetadataMutation, idempotentCreate, contentVersionSemantics, resumableUploadProviders, uploadCompletionQueryableProviders, zeroByteWriteProviders, resolvedUploadPolicyKinds, deleteSemantics, trashRestore, sse, sseResume, refreshRotationSemantics, thumbnail, providers, operations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        serverVersion = try container.decodeIfPresent(String.self, forKey: .serverVersion)
        stableItemIdentity = try container.decodeIfPresent(State.self, forKey: .stableItemIdentity) ?? .unverified
        stableRootIdentity = try container.decodeIfPresent(State.self, forKey: .stableRootIdentity) ?? .unverified
        completePagination = try container.decodeIfPresent(State.self, forKey: .completePagination) ?? .unverified
        cursorPagination = try container.decodeIfPresent(State.self, forKey: .cursorPagination) ?? .unverified
        snapshotSafePagination = try container.decodeIfPresent(State.self, forKey: .snapshotSafePagination) ?? .unverified
        conditionalContentWrite = try container.decodeIfPresent(State.self, forKey: .conditionalContentWrite) ?? .unsupported
        conditionalMetadataMutation = try container.decodeIfPresent(State.self, forKey: .conditionalMetadataMutation) ?? .unverified
        idempotentCreate = try container.decodeIfPresent(State.self, forKey: .idempotentCreate) ?? .unsupported
        contentVersionSemantics = try container.decodeIfPresent(State.self, forKey: .contentVersionSemantics) ?? .unverified
        resumableUploadProviders = try container.decodeIfPresent([String].self, forKey: .resumableUploadProviders) ?? []
        uploadCompletionQueryableProviders = try container.decodeIfPresent([String].self, forKey: .uploadCompletionQueryableProviders) ?? []
        zeroByteWriteProviders = try container.decodeIfPresent([String].self, forKey: .zeroByteWriteProviders) ?? []
        resolvedUploadPolicyKinds = try container.decodeIfPresent([String].self, forKey: .resolvedUploadPolicyKinds) ?? []
        deleteSemantics = try container.decodeIfPresent(State.self, forKey: .deleteSemantics) ?? .unsupported
        trashRestore = try container.decodeIfPresent(State.self, forKey: .trashRestore) ?? .unsupported
        sse = try container.decodeIfPresent(State.self, forKey: .sse) ?? .unverified
        sseResume = try container.decodeIfPresent(State.self, forKey: .sseResume) ?? sse
        refreshRotationSemantics = try container.decodeIfPresent(State.self, forKey: .refreshRotationSemantics) ?? .unverified
        thumbnail = try container.decodeIfPresent(State.self, forKey: .thumbnail) ?? .unverified
        providers = try container.decodeIfPresent([Provider].self, forKey: .providers) ?? []
        operations = try container.decodeIfPresent(OperationCapabilities.self, forKey: .operations) ?? OperationCapabilities(collisionSafeCreate: idempotentCreate, conditionalModify: conditionalContentWrite, metadataMove: .unverified, trash: trashRestore, purge: trashRestore, zeroByte: .unverified, resumable: .unverified, nativeConflictCopy: .unverified, fallbackConflict: .unverified)
    }

    public var allowsWrite: Bool { stableItemIdentity == .verified && stableRootIdentity == .verified && conditionalContentWrite == .verified && idempotentCreate == .verified && contentVersionSemantics == .verified }
    public func provider(named name: String) -> Provider? { providers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
    public func operationVerified(_ operation: String) -> Bool {
        let state: State
        switch operation {
        case "collision_safe_create": state = operations.collisionSafeCreate
        case "conditional_modify": state = operations.conditionalModify
        case "metadata_move": return conditionalMetadataMutation == .verified && operations.metadataMove == .verified
        case "trash": state = operations.trash
        case "purge": state = operations.purge
        case "zero_byte": state = operations.zeroByte
        case "resumable": state = operations.resumable
        case "native_conflict_copy": state = operations.nativeConflictCopy
        case "fallback_conflict": state = operations.fallbackConflict
        default: state = .unsupported
        }
        return state == .verified
    }
    public func canWrite(provider providerName: String) -> Bool {
        guard allowsWrite, let provider = provider(named: providerName) else { return false }
        return provider.write == .verified && provider.resumable == .verified && operations.conditionalModify == .verified && operations.collisionSafeCreate == .verified && operations.resumable == .verified && resumableUploadProviders.contains(where: { $0.caseInsensitiveCompare(providerName) == .orderedSame }) && uploadCompletionQueryableProviders.contains(where: { $0.caseInsensitiveCompare(providerName) == .orderedSame }) && resolvedUploadPolicyKinds.contains(where: { $0.caseInsensitiveCompare(providerName) == .orderedSame })
    }
    public func canWriteZeroByte(provider providerName: String) -> Bool {
        guard canWrite(provider: providerName), let provider = provider(named: providerName) else { return false }
        return provider.zeroByte == .verified && operations.zeroByte == .verified && zeroByteWriteProviders.contains(where: { $0.caseInsensitiveCompare(providerName) == .orderedSame })
    }
    public var canTrash: Bool { trashRestore == .verified && operations.trash == .verified }
    public var canPurge: Bool { trashRestore == .verified && deleteSemantics == .verified && operations.purge == .verified }

    /// Provider-independent write gates. The storage policy is only known per
    /// upload session, so item projection must not depend on a single
    /// configured provider name.
    public var allowsCreate: Bool { stableItemIdentity == .verified && stableRootIdentity == .verified && operations.collisionSafeCreate == .verified }
    public var allowsMetadataMove: Bool { stableItemIdentity == .verified && stableRootIdentity == .verified && conditionalMetadataMutation == .verified && operations.metadataMove == .verified }
    public var allowsContentWrite: Bool { allowsWrite && operations.conditionalModify == .verified && operations.collisionSafeCreate == .verified && operations.resumable == .verified && providers.contains { canWrite(provider: $0.name) } }
}

/// Cloudreve v4 is a known, versioned API. Its documented semantics are the
/// production capability baseline; there is no runtime probe that could ever
/// upgrade an all-`unverified` snapshot, so leaving freshly provisioned
/// domains on the fail-closed defaults made every list and write fail.
public extension CapabilitySnapshot {
    static let cloudreveV4BaselineRevision: UInt64 = 1
    /// Storage policy kinds Cloudreve v4 returns in `storage_policy.type`.
    static let cloudreveV4UploadPolicies = ["local", "remote", "oss", "qiniu", "onedrive", "cos", "upyun", "s3", "ks3", "obs"]

    static func cloudreveV4(serverVersion: String?) -> CapabilitySnapshot {
        let policies = cloudreveV4UploadPolicies
        let providers = policies.map { Provider(name: $0, read: .verified, write: .verified, resumable: .verified, zeroByte: .verified, crypto: .unverified) }
        let operations = OperationCapabilities(
            collisionSafeCreate: .verified,
            conditionalModify: .verified,
            metadataMove: .verified,
            trash: .verified,
            purge: .verified,
            zeroByte: .verified,
            resumable: .verified,
            nativeConflictCopy: .unsupported,
            fallbackConflict: .verified
        )
        return CapabilitySnapshot(
            revision: cloudreveV4BaselineRevision,
            serverVersion: serverVersion,
            stableItemIdentity: .verified,
            stableRootIdentity: .verified,
            completePagination: .verified,
            cursorPagination: .verified,
            snapshotSafePagination: .verified,
            conditionalContentWrite: .verified,
            conditionalMetadataMutation: .verified,
            idempotentCreate: .verified,
            contentVersionSemantics: .verified,
            resumableUploadProviders: policies,
            uploadCompletionQueryableProviders: policies,
            zeroByteWriteProviders: policies,
            resolvedUploadPolicyKinds: policies,
            deleteSemantics: .verified,
            trashRestore: .verified,
            sse: .verified,
            refreshRotationSemantics: .verified,
            thumbnail: .verified,
            providers: providers,
            operations: operations
        )
    }

    /// True for snapshots that were never probed: the exact all-default shape
    /// earlier builds persisted at provisioning time.
    var isUnprobedDefault: Bool { self == CapabilitySnapshot(serverVersion: serverVersion) }

    /// Migrates legacy all-default snapshots to the Cloudreve v4 baseline while
    /// leaving explicitly configured snapshots untouched.
    func upgradedToCloudreveV4Baseline() -> CapabilitySnapshot {
        isUnprobedDefault ? .cloudreveV4(serverVersion: serverVersion) : self
    }
}

public struct ItemVersion: Codable, Equatable, Sendable {
    public let content: Data
    public let metadata: Data
    public init(content: Data, metadata: Data) { self.content = content; self.metadata = metadata }
}

/// The provider-visible projection contract is independent from the
/// application version. A patch release must not invalidate content versions
/// or force a full File Provider re-enumeration.
/// Upper bound on items tracked for one sync location. Reconcile, deletion
/// detection, trash listing and rule previews share it so they either cover
/// the whole domain or fail together. The former 100k sat below a real
/// account (~150k items after a Nextcloud migration), so every full
/// reconcile failed with `normal_scan_bound`. Per-directory bounds (snapshot
/// capacity, page offsets) are separate and intentionally unchanged.
public enum DomainScale {
    public static let maximumItems = 1_000_000
}

public enum ProjectionSchema {
    // 3: metadata versions no longer fold transient transfer state and
    // capabilities come from the shared Cloudreve item mapper.
    // 4: items publish real POSIX file-system flags; earlier projections
    // exposed folders as mode 0100, so cached items must be re-emitted.
    public static let currentRevision: UInt64 = 4
    public static let itemPayloadVersion: UInt8 = 1
}

/// The single path-matching contract shared by persisted Store state and the
/// product-facing rule editor. Keeping the glob implementation here prevents
/// the File Provider and product layers from disagreeing about visibility.
public enum ExclusionMatcher {
    public static func normalize(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let negated = trimmed.hasPrefix("!")
        let pattern = negated ? String(trimmed.dropFirst()) : trimmed
        guard !pattern.isEmpty,
              !trimmed.hasPrefix("#"),
              !pattern.contains("\0"),
              !pattern.hasPrefix("/"),
              !pattern.split(separator: "/").contains("..") else {
            throw CoreFailure(code: .invalidName, retryable: false, userActionRequired: true)
        }
        let normalized = pattern.replacingOccurrences(of: "\\", with: "/")
        let directoryPattern = normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
        let escaped = NSRegularExpression.escapedPattern(for: directoryPattern)
            .replacingOccurrences(of: "\\*\\*", with: ".*")
            .replacingOccurrences(of: "\\*", with: "[^/]*")
            .replacingOccurrences(of: "\\?", with: "[^/]")
        guard (try? NSRegularExpression(pattern: "^\(escaped)(?:/.*)?$", options: [])) != nil else {
            throw CoreFailure(code: .invalidName, retryable: false, userActionRequired: true)
        }
        return negated ? "!\(directoryPattern)" : directoryPattern
    }

    public static func matches(relativePath: String, rules: [String], caseSensitive: Bool, isRoot: Bool = false) -> Bool {
        guard !isRoot else { return false }
        let path = relativePath.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var excluded = false
        for rawRule in rules {
            let negated = rawRule.hasPrefix("!")
            let pattern = negated ? String(rawRule.dropFirst()) : rawRule
            let escaped = NSRegularExpression.escapedPattern(for: pattern)
                .replacingOccurrences(of: "\\*\\*", with: ".*")
                .replacingOccurrences(of: "\\*", with: "[^/]*")
                .replacingOccurrences(of: "\\?", with: "[^/]")
            let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            // An invalid persisted rule must fail closed by hiding the item;
            // silently skipping it could expose data the user intended to
            // exclude.
            guard let expression = try? NSRegularExpression(pattern: "^\(escaped)(?:/.*)?$", options: options) else { return true }
            let range = NSRange(path.startIndex..<path.endIndex, in: path)
            if expression.firstMatch(in: path, range: range) != nil { excluded = !negated }
        }
        return excluded
    }
}

private enum ProviderContinuationCodec {
    static func isOpaque(_ value: String, maximumLength: Int) -> Bool {
        guard !value.isEmpty, value.count <= maximumLength else { return false }
        return !value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == "\\" || scalar == ":" || scalar == "@" || scalar == "?" || scalar == "#" || scalar.properties.isWhitespace
        }
    }
}

public enum AnchorValidationError: Error, Equatable, Sendable {
    case malformed
    case expired
    case checksumMismatch
    case unsupportedVersion
}

public struct RemoteItem: Codable, Equatable, Sendable {
    public let itemIdentifier: String
    public var remoteID: String?
    public var parentIdentifier: String?
    public var trashOriginalParentIdentifier: String?
    public var name: String
    public var uri: String
    public var kind: RemoteItemKind
    public var contentType: String
    public var size: Int64
    public var remoteVersion: String?
    public var version: ItemVersion
    public var creationDate: Date?
    public var contentModificationDate: Date?
    public var canRead: Bool
    public var canWrite: Bool
    public var canAddChildren: Bool
    public var canTrash: Bool
    public var canDelete: Bool
    public var trashed: Bool
    public var tombstone: Bool

    public init(itemIdentifier: String = CloudreveIdentifier.item(), remoteID: String? = nil, parentIdentifier: String? = nil, name: String, uri: String, kind: RemoteItemKind, contentType: String, size: Int64 = 0, remoteVersion: String? = nil, version: ItemVersion, creationDate: Date? = nil, contentModificationDate: Date? = nil, trashOriginalParentIdentifier: String? = nil, canRead: Bool = true, canWrite: Bool = false, canAddChildren: Bool = false, canTrash: Bool = false, canDelete: Bool = false, trashed: Bool = false, tombstone: Bool = false) {
        self.itemIdentifier = itemIdentifier; self.remoteID = remoteID; self.parentIdentifier = parentIdentifier; self.trashOriginalParentIdentifier = trashOriginalParentIdentifier; self.name = name; self.uri = uri; self.kind = kind; self.contentType = contentType; self.size = size; self.remoteVersion = remoteVersion; self.version = version; self.creationDate = creationDate; self.contentModificationDate = contentModificationDate; self.canRead = canRead; self.canWrite = canWrite; self.canAddChildren = canAddChildren; self.canTrash = canTrash; self.canDelete = canDelete; self.trashed = trashed; self.tombstone = tombstone
    }

    public func withIdentity(_ identifier: String, parentIdentifier: String? = nil) -> RemoteItem {
        RemoteItem(itemIdentifier: identifier, remoteID: remoteID, parentIdentifier: parentIdentifier ?? self.parentIdentifier, name: name, uri: uri, kind: kind, contentType: contentType, size: size, remoteVersion: remoteVersion, version: version, creationDate: creationDate, contentModificationDate: contentModificationDate, trashOriginalParentIdentifier: trashOriginalParentIdentifier, canRead: canRead, canWrite: canWrite, canAddChildren: canAddChildren, canTrash: canTrash, canDelete: canDelete, trashed: trashed, tombstone: tombstone)
    }

    /// The same remote entity under another provider identity, for when the store already knows it
    /// by a different identifier than the one a caller allocated.
    public func reidentified(as identifier: String) -> RemoteItem {
        RemoteItem(itemIdentifier: identifier, remoteID: remoteID, parentIdentifier: parentIdentifier, name: name, uri: uri, kind: kind, contentType: contentType, size: size, remoteVersion: remoteVersion, version: version, creationDate: creationDate, contentModificationDate: contentModificationDate, trashOriginalParentIdentifier: trashOriginalParentIdentifier, canRead: canRead, canWrite: canWrite, canAddChildren: canAddChildren, canTrash: canTrash, canDelete: canDelete, trashed: trashed, tombstone: tombstone)
    }
}

public enum VersionHasher {
    public static func digest(_ parts: [Data]) -> Data {
        var input = Data()
        for part in parts {
            var length = UInt64(part.count).bigEndian
            input.append(Data(bytes: &length, count: MemoryLayout<UInt64>.size))
            input.append(part)
        }
        return Data(SHA256.hash(data: input))
    }

    public static func content(primaryEntity: String) -> Data { digest([Data(primaryEntity.utf8)]) }
    public static func metadata(parent: String?, name: String, kind: RemoteItemKind, permissionBits: UInt64, revision: String?) -> Data {
        let parentData = parent.map { Data($0.utf8) } ?? Data()
        let revisionData = revision.map { Data($0.utf8) } ?? Data()
        return digest([parentData, Data(name.utf8), Data(kind.rawValue.utf8), Data(String(permissionBits).utf8), revisionData])
    }
}

/// Resolves the server's content-version evidence without treating a
/// metadata timestamp as an entity/content revision. The stable fallback is
/// suitable only for a read-only projection; callers must inspect `reliable`
/// before enabling content writes.
public struct RemoteContentVersionResolution: Equatable, Sendable {
    public let value: String
    public let reliable: Bool

    public init(value: String, reliable: Bool) {
        self.value = value
        self.reliable = reliable
    }
}

public enum RemoteContentVersionPolicy {
    public static func resolve(primaryEntity: String?, stableEntityID: String) -> RemoteContentVersionResolution {
        if let primaryEntity, !primaryEntity.isEmpty {
            return RemoteContentVersionResolution(value: primaryEntity, reliable: true)
        }
        return RemoteContentVersionResolution(value: "unversioned:\(stableEntityID)", reliable: false)
    }
}

private struct PageTokenCore: Codable, Equatable {
    let version: UInt8
    let domainIdentifier: String
    let parentIdentifier: String
    let snapshotGeneration: UInt64
    let offset: Int
    let sort: String
    let lastItemIdentifier: String?
    let workingSetRevision: UInt64?
    let projectionSchemaRevision: UInt64
    let snapshotID: String?
    let expiresAt: Int64?
}

public struct PageToken: Codable, Equatable, Sendable {
    public let version: UInt8
    public let domainIdentifier: String
    public let parentIdentifier: String
    public let snapshotGeneration: UInt64
    /// Kept for compatibility with synchronous test adapters. Working-set
    /// pages use lastItemIdentifier instead.
    public let offset: Int
    public let sort: String
    public let lastItemIdentifier: String?
    public let workingSetRevision: UInt64?
    public let projectionSchemaRevision: UInt64
    public let snapshotID: String?
    public let expiresAt: Int64?
    public let checksum: Data

    public init(
        domainIdentifier: String,
        parentIdentifier: String,
        snapshotGeneration: UInt64,
        offset: Int,
        sort: String = "name",
        lastItemIdentifier: String? = nil,
        workingSetRevision: UInt64? = nil,
        projectionSchemaRevision: UInt64 = ProjectionSchema.currentRevision,
        snapshotID: String? = nil,
        expiresAt: Int64? = nil
    ) {
        self.version = 2
        self.domainIdentifier = domainIdentifier
        self.parentIdentifier = parentIdentifier
        self.snapshotGeneration = snapshotGeneration
        self.offset = max(0, offset)
        self.sort = sort
        self.lastItemIdentifier = lastItemIdentifier
        self.workingSetRevision = workingSetRevision
        self.projectionSchemaRevision = projectionSchemaRevision
        self.snapshotID = snapshotID
        self.expiresAt = expiresAt
        self.checksum = PageToken.checksum(PageTokenCore(
            version: 2,
            domainIdentifier: domainIdentifier,
            parentIdentifier: parentIdentifier,
            snapshotGeneration: snapshotGeneration,
            offset: max(0, offset),
            sort: sort,
            lastItemIdentifier: lastItemIdentifier,
            workingSetRevision: workingSetRevision,
            projectionSchemaRevision: projectionSchemaRevision,
            snapshotID: snapshotID,
            expiresAt: expiresAt
        ))
    }

    public static func workingSet(
        domainIdentifier: String,
        lastItemIdentifier: String?,
        workingSetRevision: UInt64,
        projectionSchemaRevision: UInt64 = ProjectionSchema.currentRevision
    ) -> PageToken {
        PageToken(
            domainIdentifier: domainIdentifier,
            parentIdentifier: NSFileProviderItemIdentifier.workingSet.rawValue,
            snapshotGeneration: 0,
            offset: 0,
            sort: "item_uuid",
            lastItemIdentifier: lastItemIdentifier,
            workingSetRevision: workingSetRevision,
            projectionSchemaRevision: projectionSchemaRevision
        )
    }

    public var isWorkingSet: Bool { workingSetRevision != nil }

    public func encoded() throws -> Data {
        guard ProviderContinuationCodec.isOpaque(domainIdentifier, maximumLength: 64),
              ProviderContinuationCodec.isOpaque(parentIdentifier, maximumLength: 128),
              ProviderContinuationCodec.isOpaque(sort, maximumLength: 32),
              lastItemIdentifier.map({ ProviderContinuationCodec.isOpaque($0, maximumLength: 64) }) ?? true,
              snapshotID.map({ ProviderContinuationCodec.isOpaque($0, maximumLength: 64) }) ?? true else {
            throw CloudreveIdentifierError.sensitiveValue
        }
        let data = try JSONEncoder().encode(self)
        let result = data.base64EncodedString().data(using: .utf8)!
        guard result.count < 500 else { throw CloudreveIdentifierError.sensitiveValue }
        return result
    }

    public func validate(domainIdentifier: String, parentIdentifier: String, projectionSchemaRevision: UInt64 = ProjectionSchema.currentRevision, now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        guard version == 2 else { throw AnchorValidationError.unsupportedVersion }
        guard self.domainIdentifier == domainIdentifier, self.parentIdentifier == parentIdentifier else {
            throw AnchorValidationError.malformed
        }
        guard ProviderContinuationCodec.isOpaque(self.domainIdentifier, maximumLength: 64),
              ProviderContinuationCodec.isOpaque(self.parentIdentifier, maximumLength: 128),
              ProviderContinuationCodec.isOpaque(self.sort, maximumLength: 32),
              offset >= 0,
              offset <= 100_000,
              lastItemIdentifier.map({ ProviderContinuationCodec.isOpaque($0, maximumLength: 64) }) ?? true,
              snapshotID.map({ ProviderContinuationCodec.isOpaque($0, maximumLength: 64) }) ?? true else {
            throw AnchorValidationError.malformed
        }
        guard projectionSchemaRevision == self.projectionSchemaRevision else { throw AnchorValidationError.malformed }
        guard expiresAt.map({ $0 >= now }) ?? true else { throw AnchorValidationError.malformed }
        if parentIdentifier == NSFileProviderItemIdentifier.workingSet.rawValue {
            guard isWorkingSet,
                  snapshotGeneration == 0,
                  offset == 0,
                  sort == "item_uuid",
                  snapshotID == nil,
                  expiresAt == nil else { throw AnchorValidationError.malformed }
        } else {
            guard !isWorkingSet, workingSetRevision == nil else { throw AnchorValidationError.malformed }
            // Directory and trash pages must name a real generation. A zero
            // generation is reserved for working-set keyset pages and would
            // otherwise allow an unbound live-offset continuation through.
            guard snapshotGeneration > 0 else { throw AnchorValidationError.malformed }
        }
        let core = PageTokenCore(
            version: version,
            domainIdentifier: self.domainIdentifier,
            parentIdentifier: self.parentIdentifier,
            snapshotGeneration: snapshotGeneration,
            offset: offset,
            sort: sort,
            lastItemIdentifier: lastItemIdentifier,
            workingSetRevision: workingSetRevision,
            projectionSchemaRevision: self.projectionSchemaRevision,
            snapshotID: snapshotID,
            expiresAt: expiresAt
        )
        guard checksum == PageToken.checksum(core) else { throw AnchorValidationError.checksumMismatch }
    }

    public static func decode(_ data: Data) throws -> PageToken {
        guard data.count < 500, let encoded = Data(base64Encoded: data) else { throw AnchorValidationError.malformed }
        let token: PageToken
        do { token = try JSONDecoder().decode(PageToken.self, from: encoded) }
        catch { throw AnchorValidationError.malformed }
        guard token.version == 2 else { throw AnchorValidationError.unsupportedVersion }
        guard ProviderContinuationCodec.isOpaque(token.domainIdentifier, maximumLength: 64),
              ProviderContinuationCodec.isOpaque(token.parentIdentifier, maximumLength: 128),
              ProviderContinuationCodec.isOpaque(token.sort, maximumLength: 32),
              token.offset >= 0,
              token.offset <= 100_000,
              token.lastItemIdentifier.map({ ProviderContinuationCodec.isOpaque($0, maximumLength: 64) }) ?? true,
              token.snapshotID.map({ ProviderContinuationCodec.isOpaque($0, maximumLength: 64) }) ?? true else {
            throw AnchorValidationError.malformed
        }
        let core = PageTokenCore(
            version: token.version,
            domainIdentifier: token.domainIdentifier,
            parentIdentifier: token.parentIdentifier,
            snapshotGeneration: token.snapshotGeneration,
            offset: token.offset,
            sort: token.sort,
            lastItemIdentifier: token.lastItemIdentifier,
            workingSetRevision: token.workingSetRevision,
            projectionSchemaRevision: token.projectionSchemaRevision,
            snapshotID: token.snapshotID,
            expiresAt: token.expiresAt
        )
        guard token.checksum == checksum(core) else { throw AnchorValidationError.checksumMismatch }
        return token
    }

    private static func checksum(_ core: PageTokenCore) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(core)) ?? Data()
        return Data(VersionHasher.digest([data]).prefix(8))
    }
}

private struct SyncAnchorCore: Codable, Equatable {
    let version: UInt8
    let domainIdentifier: String
    let scope: String
    let epoch: UUID
    let sequence: UInt64
    let projectionSchemaRevision: UInt64
}

public struct SyncAnchor: Codable, Equatable, Sendable {
    public let version: UInt8
    public let domainIdentifier: String
    public let scope: String
    public let epoch: UUID
    public let sequence: UInt64
    public let projectionSchemaRevision: UInt64
    public let checksum: Data

    public init(
        domainIdentifier: String,
        scope: String,
        epoch: UUID,
        sequence: UInt64,
        projectionSchemaRevision: UInt64 = ProjectionSchema.currentRevision
    ) {
        self.version = 2
        self.domainIdentifier = domainIdentifier
        self.scope = scope
        self.epoch = epoch
        self.sequence = sequence
        self.projectionSchemaRevision = projectionSchemaRevision
        self.checksum = SyncAnchor.checksum(SyncAnchorCore(
            version: 2,
            domainIdentifier: domainIdentifier,
            scope: scope,
            epoch: epoch,
            sequence: sequence,
            projectionSchemaRevision: projectionSchemaRevision
        ))
    }

    public func encoded() throws -> Data {
        guard ProviderContinuationCodec.isOpaque(domainIdentifier, maximumLength: 64), ProviderContinuationCodec.isOpaque(scope, maximumLength: 128) else {
            throw CloudreveIdentifierError.sensitiveValue
        }
        let encoded = try JSONEncoder().encode(self).base64EncodedData()
        guard encoded.count < 500 else { throw CloudreveIdentifierError.sensitiveValue }
        return encoded
    }

    public func validate(
        domainIdentifier: String,
        scope: String,
        epoch: UUID,
        minimumSequence: UInt64,
        projectionSchemaRevision: UInt64 = ProjectionSchema.currentRevision
    ) throws {
        guard version == 2 else { throw AnchorValidationError.expired }
        guard self.domainIdentifier == domainIdentifier,
              self.scope == scope,
              self.epoch == epoch,
              self.sequence >= minimumSequence,
              self.projectionSchemaRevision == projectionSchemaRevision else {
            throw AnchorValidationError.expired
        }
        guard ProviderContinuationCodec.isOpaque(self.domainIdentifier, maximumLength: 64), ProviderContinuationCodec.isOpaque(self.scope, maximumLength: 128) else {
            throw AnchorValidationError.expired
        }
        let core = SyncAnchorCore(
            version: version,
            domainIdentifier: self.domainIdentifier,
            scope: self.scope,
            epoch: self.epoch,
            sequence: sequence,
            projectionSchemaRevision: self.projectionSchemaRevision
        )
        guard checksum == SyncAnchor.checksum(core) else { throw AnchorValidationError.checksumMismatch }
    }

    public static func decode(_ data: Data) throws -> SyncAnchor {
        guard data.count < 500, let decoded = Data(base64Encoded: data) else { throw AnchorValidationError.malformed }
        let anchor: SyncAnchor
        do { anchor = try JSONDecoder().decode(SyncAnchor.self, from: decoded) }
        catch { throw AnchorValidationError.malformed }
        guard anchor.version == 2 else { throw AnchorValidationError.expired }
        guard ProviderContinuationCodec.isOpaque(anchor.domainIdentifier, maximumLength: 64), ProviderContinuationCodec.isOpaque(anchor.scope, maximumLength: 128) else {
            throw AnchorValidationError.malformed
        }
        let core = SyncAnchorCore(
            version: anchor.version,
            domainIdentifier: anchor.domainIdentifier,
            scope: anchor.scope,
            epoch: anchor.epoch,
            sequence: anchor.sequence,
            projectionSchemaRevision: anchor.projectionSchemaRevision
        )
        guard anchor.checksum == checksum(core) else { throw AnchorValidationError.checksumMismatch }
        return anchor
    }

    private static func checksum(_ core: SyncAnchorCore) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(core)) ?? Data()
        return Data(VersionHasher.digest([data]).prefix(8))
    }
}

public enum DomainStatus: String, Codable, Sendable {
    case initializing, healthy, syncing, reconciling, offline, eventDegraded = "event_degraded", appNotRunning = "app_not_running", authExpired = "auth_expired", rootUnavailable = "root_unavailable", scopeConflict = "scope_conflict", conflict, permanentError = "permanent_error", removalPreflight = "removal_preflight", repairRequired = "repair_required", preservedRemoval = "preserved_removal"

    /// Removal/repair lifecycle states that only the removal flow may replace; runtime status writers must leave them intact.
    public static let lifecycleHold: Set<DomainStatus> = [.removalPreflight, .repairRequired, .preservedRemoval]

    public var isLifecycleHold: Bool { Self.lifecycleHold.contains(self) }
}

public struct HealthInputs: Equatable, Sendable {
    public var authenticated = false
    public var rootAvailable = false
    public var scopeValid = false
    public var hasConflict = false
    public var hasPermanentError = false
    public var offline = false
    public var reconciling = false
    public var syncing = false
    public var eventDegraded = false
    public var appRunning = false
    public var validAnchor = false
    public var recentlyReconciled = false
    public init() {}
}

public enum DomainHealthReducer {
    public static func reduce(_ input: HealthInputs) -> DomainStatus {
        if !input.authenticated { return .authExpired }
        if !input.rootAvailable { return .rootUnavailable }
        if !input.scopeValid { return .scopeConflict }
        if input.hasConflict { return .conflict }
        if input.hasPermanentError { return .permanentError }
        if input.offline { return .offline }
        if input.reconciling { return .reconciling }
        if input.syncing { return .syncing }
        if input.eventDegraded { return .eventDegraded }
        if !input.appRunning { return .appNotRunning }
        return input.validAnchor && input.recentlyReconciled ? .healthy : .reconciling
    }
}

public struct DomainDescriptor: Codable, Equatable, Sendable {
    /// The longest user-visible Domain name, for adding and renaming alike.
    public static let maxDisplayNameLength = 128

    public let identifier: String
    public var displayName: String
    public var iconURL: URL?
    public let scope: RemoteScope
    public let rootRemoteID: String
    public var currentRootURI: String
    public var accountID: String
    public var status: DomainStatus
    public var capabilitySnapshot: CapabilitySnapshot
    public var secretReference: String

    public init(identifier: String = CloudreveIdentifier.domain(), displayName: String, scope: RemoteScope, rootRemoteID: String, accountID: String, secretReference: String, capabilitySnapshot: CapabilitySnapshot = CapabilitySnapshot(), iconURL: URL? = nil) {
        self.identifier = identifier; self.displayName = displayName; self.iconURL = iconURL; self.scope = scope; self.rootRemoteID = rootRemoteID; self.currentRootURI = scope.rootURI; self.accountID = accountID; self.status = .initializing; self.capabilitySnapshot = capabilitySnapshot; self.secretReference = secretReference
    }
}

public enum CoreErrorCode: String, Codable, Sendable {
    case authentication, network, permissionDenied = "permission_denied", notFound = "not_found", quotaExceeded = "quota_exceeded", versionConflict = "version_conflict", nameCollision = "name_collision", invalidName = "invalid_name", integrityFailure = "integrity_failure", cancelled, unsupportedServer = "unsupported_server", database, unsupportedMetadata = "unsupported_metadata", rootUnavailable = "root_unavailable", scopeConflict = "scope_conflict", unknownOutcome = "unknown_outcome", awaitingSourceReplay = "awaiting_source_replay", excludedFromSync = "excluded_from_sync", directoryNotEmpty = "directory_not_empty", cannotSynchronize = "cannot_synchronize"
}

public struct CoreFailure: Error, Equatable, Sendable {
    public let code: CoreErrorCode
    public let retryable: Bool
    public let userActionRequired: Bool
    public let correlationID: UUID
    public let redactedContext: [String: String]
    public init(code: CoreErrorCode, retryable: Bool, userActionRequired: Bool = false, correlationID: UUID = UUID(), redactedContext: [String: String] = [:]) { self.code = code; self.retryable = retryable; self.userActionRequired = userActionRequired; self.correlationID = correlationID; self.redactedContext = redactedContext }
}

public enum DomainRemovalDecision: Equatable, Sendable {
    case safe
    case preserveDirtyData
    case blocked(reason: String)
}

public struct DomainRemovalPreflight: Sendable {
    public static func decide(hasDirtyWork: Bool, pendingSetReliable: Bool, waitForChangesSucceeded: Bool) -> DomainRemovalDecision {
        if hasDirtyWork || !pendingSetReliable || !waitForChangesSucceeded { return .preserveDirtyData }
        return .safe
    }
}
