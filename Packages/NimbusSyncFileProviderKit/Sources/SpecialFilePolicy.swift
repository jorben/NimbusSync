import Foundation
import Darwin
import CloudreveDomainKit

public enum SpecialFileDecision: Equatable, Sendable {
    case syncable
    case excluded
    case unsupportedMetadata
}

/// Local filesystem semantics that cannot be represented by the
/// Cloudreve/File Provider contract. Special nodes (symlinks, sockets,
/// devices, FIFOs) are excluded rather than silently turned into regular
/// uploads.
///
/// Extended attributes, Finder tags/info and resource forks are *not* a reason
/// to refuse an upload: Cloudreve only stores file contents, so this metadata
/// stays on the local copy and is simply not synchronised. Refusing them
/// previously blocked ordinary edits, because macOS routinely attaches
/// attributes such as `com.apple.lastuseddate#PS` (any opened file),
/// `com.apple.TextEncoding` (most editors) and `com.apple.FinderInfo`.
public enum SpecialFilePolicy {
    public static func decision(for url: URL) throws -> SpecialFileDecision {
        guard let mode = fileMode(atPath: url.path) else {
            throw CoreFailure(code: .notFound, retryable: false, userActionRequired: true)
        }
        let type = mode & S_IFMT
        if type == S_IFLNK || type == S_IFSOCK || type == S_IFCHR || type == S_IFBLK || type == S_IFIFO { return .excluded }
        // A contents URL always names a regular file; a directory here means
        // the caller passed the wrong object.
        if type == S_IFDIR { return .unsupportedMetadata }
        return .syncable
    }

    private static func fileMode(atPath path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode
    }
}
