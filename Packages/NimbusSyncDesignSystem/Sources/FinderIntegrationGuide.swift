import SwiftUI
import AppKit
import CloudreveDomainKit

// MARK: - Text

/// The words of the Finder integration guide, shared by the menu bar, Settings and the guide
/// window so they always name the same place in System Settings. The app is named as System
/// Settings lists it, so the Dev build points at "NimbusSyncDev", not the Release app.
public enum FinderIntegrationGuideText {
    private static let app = AppIdentity.displayName
    public static var offHeadline: String { L10n.tr("Finder integration is off") }
    public static var offDetail: String { L10n.tr("Syncing is paused until \(app) is turned on in System Settings.") }
    public static var offSubtitle: String { L10n.tr("Paused · Finder integration is off") }
    public static var bannerDetail: String { L10n.tr("Syncing is paused until you turn it on.") }
    public static var guideTitle: String { L10n.tr("Turn on \(app) in Finder") }
    public static var guideMessage: String { L10n.tr("macOS lets you choose which apps add locations to Finder. \(app) is switched off there, so your domains are hidden from Finder and nothing syncs until you turn it back on.") }
    public static var openSettingsTitle: String { L10n.tr("Open System Settings") }
    public static var laterTitle: String { L10n.tr("Later") }
    public static var checkAgainTitle: String { L10n.tr("Check Again") }
    public static var privacyNote: String { L10n.tr("Only you can turn it on — apps are not allowed to change this setting themselves.") }

    /// Where the switch lives, which moved in macOS 15.
    public static func settingsPath(majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> String {
        majorVersion >= 15
            ? L10n.tr("General › Login Items & Extensions › File Providers")
            : L10n.tr("Privacy & Security › Extensions › File Providers")
    }

    /// The numbered steps under the guide's illustration.
    public static func steps(majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> [String] {
        if majorVersion >= 15 {
            return [
                L10n.tr("Click Open System Settings."),
                L10n.tr("In Login Items & Extensions, find File Providers and click ⓘ."),
                L10n.tr("Switch on \(app), then return here."),
            ]
        }
        return [
            L10n.tr("Click Open System Settings."),
            L10n.tr("In Extensions, choose File Providers."),
            L10n.tr("Tick \(app), then return here."),
        ]
    }
}

// MARK: - Prompt policy

/// When the guide window may open by itself: only while Finder integration is off, at most once
/// per app run, and no sooner than a day after it was last shown, so a user who chose to keep it
/// off is reminded rather than nagged. The menu bar and Settings keep showing the state anyway.
public enum FinderIntegrationPromptPolicy {
    public static let lastPromptedKey = "finderIntegrationGuide.lastPromptedAt"
    public static let interval: TimeInterval = 24 * 60 * 60

    public static func shouldPrompt(state: FinderIntegrationState, alreadyPromptedThisRun: Bool, lastPromptedAt: Date?, now: Date = Date()) -> Bool {
        guard state == .off, !alreadyPromptedThisRun else { return false }
        guard let lastPromptedAt else { return true }
        return now.timeIntervalSince(lastPromptedAt) >= interval
    }

    public static func lastPrompted(in defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: lastPromptedKey) as? Date
    }

    public static func recordPrompt(at date: Date = Date(), in defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: lastPromptedKey)
    }
}

// MARK: - Illustration

/// The System Settings switch being turned on, drawn for the current appearance (see
/// `Design/FinderIntegrationGuide-*.png`). Falls back to a large symbol if the art is missing.
public struct FinderIntegrationIllustration: View {
    public let height: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    public init(height: CGFloat) {
        self.height = height
    }

    @MainActor public static let light: NSImage? = Bundle.module.image(forResource: "FinderIntegrationGuide")
    @MainActor public static let dark: NSImage? = Bundle.module.image(forResource: "FinderIntegrationGuideDark")

    public var body: some View {
        Group {
            if let image = colorScheme == .dark ? (Self.dark ?? Self.light) : (Self.light ?? Self.dark) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "switch.2")
                    .font(.system(size: height * 0.4, weight: .light))
                    .foregroundStyle(NimbusSyncDesignTokens.brandColor)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Steps

struct FinderIntegrationSteps: View {
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(NimbusSyncDesignTokens.brandColor))
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Text(step)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "General › Login Items & Extensions › File Providers" in a quiet capsule.
struct FinderIntegrationPathLabel: View {
    @ObservedObject private var localization = AppLocalization.shared
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "gearshape")
                .accessibilityHidden(true)
            Text(FinderIntegrationGuideText.settingsPath())
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .accessibilityLabel(Text("System Settings, \(FinderIntegrationGuideText.settingsPath())"))
    }
}

// MARK: - Settings card

/// The Domains page's call to action while Finder integration is off: the illustration, why it
/// matters, where the switch is and a button that goes there.
public struct FinderIntegrationGuideCard: View {
    @ObservedObject private var localization = AppLocalization.shared
    public let onOpenSettings: () -> Void
    public let onCheckAgain: () -> Void

    public init(onOpenSettings: @escaping () -> Void, onCheckAgain: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        self.onCheckAgain = onCheckAgain
    }

    public var body: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: NimbusSyncDesignTokens.spacing20) {
                FinderIntegrationIllustration(height: 150)
                    .frame(width: 230)

                VStack(alignment: .leading, spacing: NimbusSyncDesignTokens.spacing12) {
                    HStack(spacing: 8) {
                        Image(systemName: "pause.circle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(FinderIntegrationGuideText.offHeadline)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Text(FinderIntegrationGuideText.guideMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    FinderIntegrationPathLabel()
                    FinderIntegrationSteps(steps: FinderIntegrationGuideText.steps())
                    HStack(spacing: NimbusSyncDesignTokens.spacing8) {
                        Button(action: onOpenSettings) {
                            Label(FinderIntegrationGuideText.openSettingsTitle, systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(.borderedProminent)
                        Button(FinderIntegrationGuideText.checkAgainTitle, action: onCheckAgain)
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(NimbusSyncDesignTokens.spacing20)
        }
        .overlay(
            RoundedRectangle(cornerRadius: NimbusSyncDesignTokens.settingsCardRadius, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
        )
    }
}

// MARK: - Guide window

/// The window NimbusSync opens by itself when it finds Finder integration off. It closes on its
/// own once the switch is turned on (see the app delegate).
public struct FinderIntegrationGuideView: View {
    @ObservedObject private var localization = AppLocalization.shared
    public let onOpenSettings: () -> Void
    public let onLater: () -> Void

    public init(onOpenSettings: @escaping () -> Void, onLater: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        self.onLater = onLater
    }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(
                    colors: [NimbusSyncDesignTokens.brandColor.opacity(0.14), NimbusSyncDesignTokens.brandColor.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                FinderIntegrationIllustration(height: 210)
                    .padding(.top, 34)
                    .padding(.bottom, 8)
            }
            .frame(height: 252)

            VStack(alignment: .leading, spacing: 14) {
                Text(FinderIntegrationGuideText.guideTitle)
                    .font(.system(size: 20, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text(FinderIntegrationGuideText.guideMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                FinderIntegrationPathLabel()
                FinderIntegrationSteps(steps: FinderIntegrationGuideText.steps())
                Text(FinderIntegrationGuideText.privacyNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: NimbusSyncDesignTokens.spacing8) {
                Spacer()
                Button(FinderIntegrationGuideText.laterTitle, action: onLater)
                    .keyboardShortcut(.cancelAction)
                Button(action: onOpenSettings) {
                    Label(FinderIntegrationGuideText.openSettingsTitle, systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.locale, localization.locale)
        .tint(NimbusSyncDesignTokens.brandColor)
    }
}
