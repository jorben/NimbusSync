import SwiftUI
import AppKit
import CloudreveDomainKit

// MARK: - Summary

/// The one-line overview under the Domains title: "1 syncing • 1 up to date • No issues".
public struct SettingsDomainsSummary: Equatable, Sendable {
    public let syncing: Int
    public let upToDate: Int
    public let needsAttention: Int

    public init(domains: [DomainDescriptor]) {
        syncing = domains.filter { [.syncing, .reconciling, .initializing].contains($0.status) }.count
        upToDate = domains.filter { $0.status == .healthy }.count
        needsAttention = domains.filter { $0.status.needsAttention }.count
    }

    public var issuesText: String {
        needsAttention == 0 ? "No issues" : "\(needsAttention) need\(needsAttention == 1 ? "s" : "") attention"
    }

    /// The whole line as one sentence, for VoiceOver and tests.
    public var text: String {
        var parts: [String] = []
        if syncing > 0 { parts.append("\(syncing) syncing") }
        if upToDate > 0 { parts.append("\(upToDate) up to date") }
        parts.append(issuesText)
        return parts.joined(separator: " • ")
    }
}

public struct SettingsDomainsSummaryLine: View {
    public let summary: SettingsDomainsSummary

    public init(summary: SettingsDomainsSummary) {
        self.summary = summary
    }

    public var body: some View {
        HStack(spacing: 10) {
            if summary.syncing > 0 {
                item(symbol: "arrow.triangle.2.circlepath", tint: NimbusSyncDesignTokens.brandColor, text: "\(summary.syncing) syncing")
                separator
            }
            if summary.upToDate > 0 {
                item(symbol: "checkmark.circle.fill", tint: .green, text: "\(summary.upToDate) up to date")
                separator
            }
            if summary.needsAttention > 0 {
                item(symbol: "exclamationmark.triangle.fill", tint: .orange, text: summary.issuesText)
            } else {
                Text(summary.issuesText)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(summary.text))
    }

    private func item(symbol: String, tint: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
        }
    }

    private var separator: some View {
        Circle()
            .fill(Color.secondary.opacity(0.6))
            .frame(width: 4, height: 4)
    }
}

// MARK: - Text

public enum SettingsDomainText {
    /// "Last synced just now", "Last synced 2 min. ago", "Last synced Today, 09:12",
    /// "Last synced Yesterday, 18:40", "Last synced Nov 3, 09:12"; "Not synced yet" without a date.
    public static func lastSynced(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "Not synced yet" }
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "Last synced just now" }
        if elapsed < 3600 { return "Last synced \(TaskDisplay.relativeTime(date, relativeTo: now))" }
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Last synced Today, \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Last synced Yesterday, \(time)"
        }
        return "Last synced \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    /// A local path with the user's home folder written as "~".
    public static func displayPath(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// The server's host for display: "cloudreve.example.com", keeping a non-default port.
    public static func host(of origin: String) -> String {
        guard let components = URLComponents(string: origin), let host = components.host else { return origin }
        if let port = components.port { return "\(host):\(port)" }
        return host
    }
}

// MARK: - Card

/// A rounded, outlined group on the Settings window's content background.
public struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: NimbusSyncDesignTokens.settingsCardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.55 : 1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: NimbusSyncDesignTokens.settingsCardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.1))
        )
    }
}

/// One Domain on the Settings Domains page: who it is and how it is doing on top, a running
/// check underneath when there is one, and where it lives locally along the bottom.
public struct SettingsDomainCard<MenuItems: View>: View {
    public let domain: DomainDescriptor
    public let connection: ServerConnectionDisplay
    public let progress: DomainCheckProgress?
    /// The Domain's folder as the user sees it, already shortened for display.
    public let localPath: String?
    public let lastSyncedAt: Date?
    public let isRemoving: Bool
    /// Another Domain is being removed; row actions wait for it.
    public let actionsDisabled: Bool
    public let onOpenFinder: () -> Void
    public let onOpenWeb: () -> Void
    @ViewBuilder public let menuItems: () -> MenuItems

    public init(
        domain: DomainDescriptor,
        connection: ServerConnectionDisplay,
        progress: DomainCheckProgress?,
        localPath: String?,
        lastSyncedAt: Date?,
        isRemoving: Bool,
        actionsDisabled: Bool,
        onOpenFinder: @escaping () -> Void,
        onOpenWeb: @escaping () -> Void,
        @ViewBuilder menuItems: @escaping () -> MenuItems
    ) {
        self.domain = domain
        self.connection = connection
        self.progress = progress
        self.localPath = localPath
        self.lastSyncedAt = lastSyncedAt
        self.isRemoving = isRemoving
        self.actionsDisabled = actionsDisabled
        self.onOpenFinder = onOpenFinder
        self.onOpenWeb = onOpenWeb
        self.menuItems = menuItems
    }

    public var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let progress {
                    SettingsCheckProgressView(progress: progress)
                }
                Divider()
                details
            }
            .padding(NimbusSyncDesignTokens.spacing16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(domain.displayName), \(domain.status.title)"))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            DomainLogoTile(size: 52)

            VStack(alignment: .leading, spacing: 4) {
                // The badge never shrinks, so on a narrow card it moves under the name rather
                // than squeezing the name down to an ellipsis.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        name.fixedSize()
                        StatusBadge(status: domain.status)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        name
                        StatusBadge(status: domain.status)
                    }
                }
                HStack(spacing: 7) {
                    ServerConnectionDot(connection: connection)
                    SettingsLinkButton(title: SettingsDomainText.host(of: domain.scope.origin), action: onOpenWeb)
                        .help("Open \(domain.scope.origin) in your browser")
                        .accessibilityLabel(Text("Open \(SettingsDomainText.host(of: domain.scope.origin)) in your browser"))
                }
            }

            Spacer(minLength: NimbusSyncDesignTokens.spacing12)

            actions
        }
    }

    private var name: some View {
        Text(domain.displayName)
            .font(.system(size: 17, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .help(domain.displayName)
    }

    @ViewBuilder
    private var actions: some View {
        if isRemoving {
            HStack(spacing: NimbusSyncDesignTokens.spacing8) {
                ProgressView().controlSize(.small)
                Text("Removing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Removing \(domain.displayName)"))
        } else {
            HStack(spacing: NimbusSyncDesignTokens.spacing8) {
                Button(action: onOpenFinder) {
                    Image(systemName: "folder")
                }
                .buttonStyle(SettingsIconButtonStyle())
                .help("Open in Finder")
                .accessibilityLabel(Text("Open \(domain.displayName) in Finder"))

                Menu(content: menuItems) {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                // A borderless menu draws its label in the accent colour; match the other buttons.
                .tint(Color.primary.opacity(0.75))
                .fixedSize()
                .modifier(SettingsIconChrome())
                .help("More actions")
                .accessibilityLabel(Text("More actions for \(domain.displayName)"))
            }
            .disabled(actionsDisabled)
        }
    }

    /// Where the Domain lives on this Mac on the left, when it last synced on the right. The
    /// path gives way (truncating in the middle) so the time always stays whole.
    private var details: some View {
        HStack(spacing: NimbusSyncDesignTokens.spacing16) {
            pathItem
            Spacer(minLength: 0)
            syncedItem
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var pathItem: some View {
        if let localPath {
            DetailItem(symbol: "folder") {
                Text(localPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(localPath)
            }
            .accessibilityLabel(Text("Local folder \(localPath)"))
        }
    }

    private var syncedItem: some View {
        DetailItem(symbol: "clock") {
            Text(SettingsDomainText.lastSynced(lastSyncedAt))
                .lineLimit(1)
                .help(lastSyncedAt.map { $0.formatted(date: .complete, time: .standard) } ?? "")
        }
        .fixedSize()
    }
}

/// A Domain's server connection as a single coloured dot; the words appear on hover and are
/// read by VoiceOver.
public struct ServerConnectionDot: View {
    public let connection: ServerConnectionDisplay

    public init(connection: ServerConnectionDisplay) {
        self.connection = connection
    }

    public var body: some View {
        Circle()
            .fill(connection.kind.tint)
            .frame(width: 8, height: 8)
            .padding(4)
            .contentShape(Rectangle())
            .help(Self.helpText(connection))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Server connection: \(connection.kind.title)"))
    }

    /// "Connected · Since 10:32", or the state alone when there is no time to add.
    public static func helpText(_ connection: ServerConnectionDisplay, now: Date = Date()) -> String {
        [connection.kind.title, connection.detail(relativeTo: now)].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct DetailItem<Content: View>: View {
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 18)
                .accessibilityHidden(true)
            content
        }
        .accessibilityElement(children: .combine)
    }
}

/// The Cloudreve logo on a soft, outlined tile.
public struct DomainLogoTile: View {
    public let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    public init(size: CGFloat = 52) {
        self.size = size
    }

    public var body: some View {
        DomainIconView(size: size * 0.72)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1))
            )
            .accessibilityHidden(true)
    }
}

/// An underlined link in the brand colour with a trailing "opens elsewhere" glyph.
public struct SettingsLinkButton: View {
    public let title: String
    public let action: () -> Void
    @State private var isHovered = false

    public init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .underline(isHovered)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityHidden(true)
            }
            .font(.callout)
            .foregroundStyle(NimbusSyncDesignTokens.brandColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard hovering != isHovered else { return }
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            if isHovered { NSCursor.pop() }
            isHovered = false
        }
    }
}

/// The card's running full check: what it is doing and how long is left, over a bar.
public struct SettingsCheckProgressView: View {
    public let progress: DomainCheckProgress

    public init(progress: DomainCheckProgress) {
        self.progress = progress
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: NimbusSyncDesignTokens.spacing8) {
                Text(PopoverCheckProgressText.activity(progress))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: NimbusSyncDesignTokens.spacing8)
                if let trailing = PopoverCheckProgressText.estimate(progress) {
                    Text(trailing)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .font(.callout.monospacedDigit())

            if let fraction = progress.estimatedFraction {
                PopoverProgressBar(fraction: fraction, height: 6)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Checking for updates"))
        .accessibilityValue(Text(DomainCheckProgressView.summary(progress)))
    }
}

/// The Domains page with nothing added yet.
public struct SettingsDomainsEmptyState: View {
    public let onAddDomain: () -> Void

    public init(onAddDomain: @escaping () -> Void) {
        self.onAddDomain = onAddDomain
    }

    public var body: some View {
        SettingsCard {
            VStack(spacing: NimbusSyncDesignTokens.spacing12) {
                DomainLogoTile(size: 64)
                Text("Connect your first domain")
                    .font(.title3.weight(.semibold))
                Text("Add a Cloudreve server to make its files available in your Finder sidebar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onAddDomain) {
                    Label("Add Domain", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, NimbusSyncDesignTokens.spacing4)
            }
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
            .padding(.horizontal, NimbusSyncDesignTokens.spacing20)
        }
    }
}

// MARK: - Buttons

/// A square, softly filled and outlined icon button, as used for a Domain card's actions.
public struct SettingsIconButtonStyle: ButtonStyle {
    public var size: CGFloat

    public init(size: CGFloat = NimbusSyncDesignTokens.settingsIconButtonSize) {
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        SettingsIconButton(configuration: configuration, size: size)
    }

    private struct SettingsIconButton: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.primary.opacity(isEnabled ? 0.75 : 0.3))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(fillOpacity))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(isEnabled ? 0.08 : 0.04))
                )
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }

        private var fillOpacity: Double {
            guard isEnabled else { return 0.02 }
            if configuration.isPressed { return 0.14 }
            return isHovered ? 0.09 : 0.05
        }
    }
}

/// A Menu ignores ButtonStyle, so its label gets the icon button's frame and fill here.
struct SettingsIconChrome: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 15, weight: .medium))
            .frame(width: NimbusSyncDesignTokens.settingsIconButtonSize, height: NimbusSyncDesignTokens.settingsIconButtonSize)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isEnabled ? (isHovered ? 0.09 : 0.05) : 0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isEnabled ? 0.08 : 0.04))
            )
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

// MARK: - Sidebar

/// Whether Finder shows NimbusSync's locations: macOS lets the user switch a File Provider off.
public enum FinderIntegrationState: Equatable, Sendable {
    case unknown
    /// No Domain is registered with macOS yet.
    case notSetUp
    case on
    /// Every registered location is switched off in System Settings.
    case off

    public var title: String {
        switch self {
        case .unknown: "Checking…"
        case .notSetUp: "Not set up"
        case .on: "On"
        case .off: "Off"
        }
    }

    public var tint: Color {
        switch self {
        case .on: .green
        case .off: .orange
        case .unknown, .notSetUp: .secondary
        }
    }
}

/// The sidebar's foot: Finder's icon and whether NimbusSync appears there.
public struct FinderIntegrationFooter: View {
    public let state: FinderIntegrationState
    public let onOpenSettings: () -> Void

    public init(state: FinderIntegrationState, onOpenSettings: @escaping () -> Void) {
        self.state = state
        self.onOpenSettings = onOpenSettings
    }

    @MainActor private static let finderIcon = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")

    public var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: Self.finderIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Finder integration")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        Circle().fill(state.tint).frame(width: 7, height: 7)
                        Text(state.title)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .fixedSize()
                }
                if state == .off {
                    Button("Turn on in System Settings", action: onOpenSettings)
                        .buttonStyle(.link)
                        .font(.caption)
                } else {
                    Text("Managed by File Provider")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A small grey count beside a sidebar item.
public struct SidebarCountBadge: View {
    public let count: Int

    public init(count: Int) {
        self.count = count
    }

    public var body: some View {
        Text("\(count)")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(minWidth: 20, minHeight: 20)
            .background(Capsule().fill(Color.secondary.opacity(0.75)))
            .accessibilityLabel(Text("\(count)"))
    }
}

/// The Settings sidebar's fill: the system sidebar material under a cool brand-tinted veil.
/// The material alone takes its colour from the wallpaper (often a flat grey); the veil keeps
/// the light periwinkle of the design while a little of the translucency still shows through.
public struct SettingsSidebarBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        ZStack {
            VisualEffectBackground(material: .sidebar)
            Rectangle()
                .fill(colorScheme == .dark
                    ? Color(red: 28 / 255, green: 33 / 255, blue: 46 / 255).opacity(0.7)
                    : NimbusSyncDesignTokens.settingsSidebarTint.opacity(0.9))
        }
        .accessibilityHidden(true)
    }
}

/// An AppKit material behind SwiftUI content, for the translucent sidebar.
public struct VisualEffectBackground: NSViewRepresentable {
    public let material: NSVisualEffectView.Material
    public let blendingMode: NSVisualEffectView.BlendingMode

    public init(material: NSVisualEffectView.Material = .sidebar, blendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    public func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

// MARK: - Appearance

/// The app's colour scheme, chosen in Settings › General. It applies to every NimbusSync window,
/// the menu bar popover included.
public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public static let preferenceKey = "appearance"

    public var id: Self { self }

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// nil hands the choice back to macOS.
    public var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    /// The stored choice; anything unreadable falls back to following the system.
    public static func stored(in defaults: UserDefaults = .standard) -> AppAppearance {
        defaults.string(forKey: preferenceKey).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    @MainActor public func apply() {
        NSApp.appearance = appearanceName.flatMap(NSAppearance.init(named:))
    }
}
