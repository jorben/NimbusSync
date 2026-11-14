import Foundation

/// Presentation of stable error codes shared by product UI and Finder item errors. Stored codes
/// and unknown server-provided messages are left unchanged.
public enum SyncErrorText {
    private static let sourceTitles = [
        "network": "Network error", "authentication": "Sign-in required", "authentication_required": "Sign-in required",
        "permission_denied": "Permission denied", "not_found": "Not found on server", "quota_exceeded": "Storage full",
        "version_conflict": "Changed on both sides", "name_collision": "Name already in use", "invalid_name": "Name not allowed",
        "integrity_failure": "Integrity check failed", "unknown_outcome": "Outcome unknown", "unsupported_server": "Server not supported",
        "root_unavailable": "Remote root unavailable", "excluded_from_sync": "Excluded from sync", "directory_not_empty": "Folder not empty",
        "cannot_synchronize": "Can't sync right now", "awaiting_source_replay": "Waiting for the local copy",
        "cancelled": "Cancelled", "database": "Database error", "unsupported_metadata": "Operation not supported",
        "scope_conflict": "Domain scope conflict", "download_failed": "Download failed", "upload_failed": "Upload failed",
    ]

    public static func title(for code: String) -> String? {
        sourceTitles[code.lowercased()].map { L10n.text($0) }
    }
}
