import CloudreveDomainKit
import Foundation

// In-app updates (Sparkle). The app target owns the Sparkle updater; everything it decides from
// plain values lives here so it can be tested without Sparkle or a bundle.

/// Whether this build may update itself, from its Info.plist.
///
/// Only the Release identity updates (`NimbusSyncUpdatesEnabled`, see `Config/*.xcconfig`), and
/// only with a feed and an EdDSA public key: Sparkle refuses unsigned archives, so a build
/// without the key could never install anything and would only report errors.
public struct AppUpdateConfiguration: Equatable, Sendable {
    public static let enabledInfoKey = "NimbusSyncUpdatesEnabled"
    public static let feedURLInfoKey = "SUFeedURL"
    public static let publicKeyInfoKey = "SUPublicEDKey"

    public enum Unavailability: Equatable, Sendable {
        /// The Dev build, SwiftPM tests and tools.
        case disabledForBuild
        case missingFeed
        case missingPublicKey
    }

    /// nil when the updater may start.
    public let unavailability: Unavailability?

    public var isEnabled: Bool { unavailability == nil }

    public init(enabledFlag: String?, feedURL: String?, publicKey: String?) {
        if Self.normalized(enabledFlag)?.uppercased() != "YES" {
            unavailability = .disabledForBuild
        } else if Self.normalized(feedURL).flatMap(URL.init(string:)).map({ $0.scheme == "https" }) != true {
            unavailability = .missingFeed
        } else if Self.normalized(publicKey) == nil {
            unavailability = .missingPublicKey
        } else {
            unavailability = nil
        }
    }

    public init(bundle: Bundle) {
        self.init(
            enabledFlag: bundle.object(forInfoDictionaryKey: Self.enabledInfoKey) as? String,
            feedURL: bundle.object(forInfoDictionaryKey: Self.feedURLInfoKey) as? String,
            publicKey: bundle.object(forInfoDictionaryKey: Self.publicKeyInfoKey) as? String
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }
}

/// The beta channel opt-in, chosen in Settings › General.
///
/// Prereleases are published to the appcast's `beta` channel; stable releases carry no channel,
/// which Sparkle always includes. A build that is itself a prerelease (its version has a suffix
/// such as `-rc.1`) starts opted in, so testers keep receiving the next candidate; everyone else
/// starts on stable only.
public enum BetaUpdatesPreference {
    public static let preferenceKey = "receivesBetaUpdates"
    public static let betaChannel = "beta"

    public static func defaultValue(forVersion version: String?) -> Bool {
        guard let version else { return false }
        return version.contains("-")
    }

    public static func stored(in defaults: UserDefaults = .standard, version: String? = AppIdentity.version) -> Bool {
        defaults.object(forKey: preferenceKey) as? Bool ?? defaultValue(forVersion: version)
    }

    /// The channels Sparkle may offer updates from, besides the default (stable) channel.
    public static func allowedChannels(receivesBetas: Bool) -> Set<String> {
        receivesBetas ? [betaChannel] : []
    }
}

/// What the app shows about an update outside Sparkle's own windows: a badge on the menu bar
/// item and a banner in the menu bar panel.
///
/// - `available`: a scheduled check found an update the user has not looked at yet. Opening it
///   (the banner, or Check for Updates…) brings up Sparkle's update window.
/// - `readyToInstall`: automatic updates downloaded it; it installs when NimbusSync quits, or
///   now with Restart to Update.
public enum AppUpdateStatus: Equatable, Sendable {
    case none
    case available(version: String)
    case readyToInstall(version: String)

    public var showsBadge: Bool { self != .none }

    public var bannerTitle: String? {
        switch self {
        case .none: nil
        case .available(let version): L10n.tr("\(AppIdentity.displayName) \(version) is available")
        case .readyToInstall(let version): L10n.tr("\(AppIdentity.displayName) \(version) is ready")
        }
    }

    public var bannerDetail: String {
        switch self {
        case .none: ""
        case .available: L10n.tr("See what's new and install the update.")
        case .readyToInstall: L10n.tr("Restart to finish updating, or it installs when you quit.")
        }
    }

    public var bannerSymbol: String {
        switch self {
        case .none, .available: "arrow.down.circle.fill"
        case .readyToInstall: "arrow.clockwise.circle.fill"
        }
    }

    public var bannerActionTitle: String? {
        switch self {
        case .none: nil
        case .available: L10n.tr("View")
        case .readyToInstall: L10n.tr("Restart")
        }
    }

    /// Appended to the menu bar item's VoiceOver label and tooltip.
    public var accessibilitySuffix: String? {
        switch self {
        case .none: nil
        case .available: L10n.tr("Update available")
        case .readyToInstall: L10n.tr("Update ready to install")
        }
    }
}

/// The text Settings › General shows under Check for Updates….
public enum AppUpdateSettingsText {
    public static func lastChecked(_ date: Date?, now: Date = Date(), locale: Locale = L10n.locale) -> String {
        guard let date else { return L10n.tr("Never checked") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        if now.timeIntervalSince(date) < 60 { return L10n.tr("Last checked just now") }
        return L10n.tr("Last checked \(formatter.localizedString(for: date, relativeTo: now))")
    }

    public static func unavailableReason(_ reason: AppUpdateConfiguration.Unavailability) -> String {
        switch reason {
        case .disabledForBuild: L10n.tr("\(AppIdentity.displayName) development builds don't update themselves.")
        case .missingFeed: L10n.tr("This build has no update feed.")
        case .missingPublicKey: L10n.tr("This build has no update signing key.")
        }
    }
}
