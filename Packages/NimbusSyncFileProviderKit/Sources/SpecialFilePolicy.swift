import Foundation
import Darwin
import CloudreveDomainKit

public enum SpecialFileDecision: Equatable, Sendable {
    case syncable
    case excluded
    case unsupportedMetadata
}

/// Fixed 1.0 policy for local filesystem semantics that cannot be represented
/// by the Cloudreve/File Provider contract. The policy never silently turns a
/// special node into an ordinary uploaded file.
public enum SpecialFilePolicy {
    public static func decision(for url: URL) throws -> SpecialFileDecision {
        guard let mode = fileMode(atPath: url.path) else {
            throw CoreFailure(code: .notFound, retryable: false, userActionRequired: true)
        }
        let type = mode & S_IFMT
        if type == S_IFLNK || type == S_IFSOCK || type == S_IFCHR || type == S_IFBLK || type == S_IFIFO { return .excluded }
        if type == S_IFDIR { return .unsupportedMetadata }
        if hasUnsupportedExtendedAttributes(atPath: url.path) || nonEmptyResourceFork(atPath: url.path) { return .unsupportedMetadata }
        return .syncable
    }

    private static func hasUnsupportedExtendedAttributes(atPath path: String) -> Bool {
        let size = path.withCString { listxattr($0, nil, 0, XATTR_NOFOLLOW) }
        guard size >= 0 else { return true }
        guard size > 0 else { return false }
        var buffer = [CChar](repeating: 0, count: Int(size))
        let actual = path.withCString { listxattr($0, &buffer, buffer.count, XATTR_NOFOLLOW) }
        guard actual >= 0 else { return true }
        guard actual > 0 else { return false }
        let bytes = buffer.prefix(Int(actual)).map { UInt8(bitPattern: $0) }
        let systemAttributes: Set<String> = [
            "com.apple.ResourceFork",
            "com.apple.quarantine",
            "com.apple.provenance",
            "com.apple.macl",
            "com.apple.metadata:kMDItemWhereFroms",
            "com.apple.metadata:kMDItemDownloadedDate",
            "com.apple.decmpfs",
        ]
        for rawName in Data(bytes).split(separator: 0) {
            let name = String(decoding: rawName, as: UTF8.self)
            if name == "com.apple.ResourceFork" {
                if nonEmptyResourceFork(atPath: path) { return true }
            } else if !systemAttributes.contains(name) {
                // 1.0 does not carry arbitrary xattrs, Finder tags/comments,
                // ACLs, or quarantine metadata across the Cloudreve contract.
                // Refuse the upload rather than silently dropping them.
                return true
            }
        }
        return false
    }

    private static func nonEmptyResourceFork(atPath path: String) -> Bool {
        path.withCString { pointer in
            let size = getxattr(pointer, "com.apple.ResourceFork", nil, 0, 0, 0)
            if size > 0 { return true }
            if size == 0 { return false }
            return errno != ENOATTR && errno != ENOTSUP
        }
    }

    private static func fileMode(atPath path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode
    }
}
