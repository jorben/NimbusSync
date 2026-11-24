import CloudreveDomainKit

/// What the app says when a Domain's File Provider extension is unavailable.
public enum ExtensionIssueText {
    /// Source keys; the banner localizes them.
    public static let title = "Finder can't load your files"

    public static func detail(_ reason: ExtensionUnavailableReason) -> String {
        switch reason {
        case .notResponding:
            "The File Provider extension isn't responding. Quit and reopen NimbusSync; if it continues, restart your Mac."
        case .staleCopy:
            "macOS is running the extension from another copy of NimbusSync. Delete other NimbusSync copies, then restart your Mac."
        }
    }
}
