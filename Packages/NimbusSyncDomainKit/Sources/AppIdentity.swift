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
    public static let displayNameInfoKey = "NimbusSyncDisplayName"
    public static let versionInfoKey = "NimbusSyncVersion"
    public static let releaseDisplayName = "NimbusSync"

    /// The main app's bundle identifier; extensions append `.fileprovider` / `.fileproviderui`.
    public static let baseIdentifier: String = infoValue(baseIdentifierInfoKey) ?? releaseBaseIdentifier

    public static let appGroupIdentifier: String = infoValue(appGroupInfoKey) ?? "group.\(baseIdentifier)"

    /// The scheme NimbusSync's own deep links use. The Cloudreve OAuth callback scheme is fixed by
    /// the server and is shared by every build.
    public static let urlScheme: String = infoValue(urlSchemeInfoKey) ?? releaseURLScheme

    /// The name the build shows itself under: "NimbusSync", or "NimbusSyncDev" for the Dev build,
    /// so the two can be told apart in the menu bar, Settings and the guide that points at System
    /// Settings (where macOS lists each build by its bundle name).
    public static let displayName: String = infoValue(displayNameInfoKey) ?? releaseDisplayName

    /// The full version of this build, e.g. "0.1.0-rc.3": the release tag CI built from, which
    /// keeps the pre-release suffix that CFBundleShortVersionString must drop. Falls back to
    /// CFBundleShortVersionString, and is nil outside a bundled build.
    public static let version: String? = version(
        full: Bundle.main.object(forInfoDictionaryKey: versionInfoKey) as? String,
        short: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    )

    /// Resolves the version from the Info.plist values: the full version when it was stamped, otherwise
    /// the numeric short version.
    public static func version(full: String?, short: String?) -> String? {
        normalized(full) ?? normalized(short)
    }

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
        normalized(bundle.object(forInfoDictionaryKey: key) as? String)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unexpanded build setting means the target is missing its xcconfig; treat as absent.
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }
}
