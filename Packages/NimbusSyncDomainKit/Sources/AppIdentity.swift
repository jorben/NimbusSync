import Foundation

/// The identity a NimbusSync build runs under, shared by the app and its extensions.
///
/// Release and Dev builds use separate identities so both can be installed on one Mac: each has
/// its own bundle-ID base, App Group, Keychain access group and deep-link scheme. The build
/// writes these values into every target's Info.plist (see `Config/*.xcconfig`); processes
/// without them (SwiftPM tests, tools) fall back to the Release identity.
public enum AppIdentity {
    public static let releaseBaseIdentifier = "io.github.jorben.nimbussync"
    public static let releaseURLScheme = "nimbussync"

    public static let baseIdentifierInfoKey = "NimbusSyncBundleIdentifierBase"
    public static let appGroupInfoKey = "NimbusSyncAppGroupIdentifier"
    public static let urlSchemeInfoKey = "NimbusSyncURLScheme"

    /// The main app's bundle identifier; extensions append `.fileprovider` / `.fileproviderui`.
    public static let baseIdentifier: String = infoValue(baseIdentifierInfoKey) ?? releaseBaseIdentifier

    public static let appGroupIdentifier: String = infoValue(appGroupInfoKey) ?? "group.\(baseIdentifier)"

    /// The scheme NimbusSync's own deep links use. The Cloudreve OAuth callback scheme is fixed by
    /// the server and is shared by every build.
    public static let urlScheme: String = infoValue(urlSchemeInfoKey) ?? releaseURLScheme

    /// The extension role of `bundleIdentifier` within the identity rooted at `baseIdentifier`.
    public static func role(of bundleIdentifier: String?, baseIdentifier: String = baseIdentifier) -> Role? {
        switch bundleIdentifier {
        case baseIdentifier: .app
        case "\(baseIdentifier).fileprovider": .fileProvider
        case "\(baseIdentifier).fileproviderui": .fileProviderUI
        default: nil
        }
    }

    public enum Role: Sendable, Equatable { case app, fileProvider, fileProviderUI }

    static func infoValue(_ key: String, bundle: Bundle = .main) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unexpanded build setting means the target is missing its xcconfig; treat as absent.
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }
}
