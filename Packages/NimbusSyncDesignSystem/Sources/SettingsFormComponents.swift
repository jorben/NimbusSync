import SwiftUI
import AppKit
import CloudreveDomainKit

// The building blocks of the General, Diagnostics and About pages. They speak the Domains page's
// language — outlined cards, tinted icon tiles, the same type scale and insets — so every
// Settings page reads as one design rather than a system form next to custom cards.

// MARK: - Group

/// A titled card of rows with an optional explanation underneath, like a System Settings group.
public struct SettingsGroup<Content: View, Footer: View>: View {
    @ObservedObject private var localization = AppLocalization.shared
    public let title: String?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    public init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content, @ViewBuilder footer: @escaping () -> Footer) {
        self.title = title
        self.content = content
        self.footer = footer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NimbusSyncDesignTokens.spacing8) {
            if let title {
                Text(L10n.text(title))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                    .accessibilityAddTraits(.isHeader)
            }
            SettingsCard {
                content()
            }
            footer()
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public extension SettingsGroup where Footer == EmptyView {
    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, content: content, footer: { EmptyView() })
    }
}

// MARK: - Row

/// One setting: a tinted icon tile, a title with an optional line of explanation, and the
/// control on the right. A nested row drops the tile and lines up under its parent's title.
public struct SettingsRow<Trailing: View>: View {
    @ObservedObject private var localization = AppLocalization.shared
    public let symbol: String?
    public let tint: Color
    public let title: String
    public let subtitle: String?
    public let isNested: Bool
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.isEnabled) private var isEnabled

    public init(
        symbol: String? = nil,
        tint: Color = NimbusSyncDesignTokens.brandTextColor,
        title: String,
        subtitle: String? = nil,
        isNested: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.isNested = isNested
        self.trailing = trailing
    }

    public var body: some View {
        HStack(alignment: .center, spacing: NimbusSyncDesignTokens.spacing12) {
            if isNested {
                Color.clear
                    .frame(width: SettingsRowMetrics.tileSize, height: 1)
                    .accessibilityHidden(true)
            } else if let symbol {
                SettingsIconTile(symbol: symbol, tint: tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(title))
                    .font(.system(size: isNested ? 13 : 14, weight: isNested ? .regular : .medium))
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                if let subtitle {
                    Text(L10n.text(subtitle))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing()
        }
        .padding(.horizontal, NimbusSyncDesignTokens.spacing16)
        .padding(.vertical, isNested ? 9 : NimbusSyncDesignTokens.spacing12)
        .frame(minHeight: isNested ? 38 : 56)
    }
}

public extension SettingsRow where Trailing == EmptyView {
    init(symbol: String? = nil, tint: Color = NimbusSyncDesignTokens.brandTextColor, title: String, subtitle: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

/// A Settings switch with its row's title as the accessible label, drawn at System Settings' size.
public struct SettingsSwitch: View {
    @ObservedObject private var localization = AppLocalization.shared
    public let title: String
    @Binding public var isOn: Bool

    public init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    public var body: some View {
        Toggle(L10n.text(title), isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
    }
}

public enum SettingsRowMetrics {
    public static let tileSize: CGFloat = 30
}

/// The hairline between two rows of a card, starting under the text so the tiles read as a column.
public struct SettingsRowDivider: View {
    public let inset: Bool

    public init(inset: Bool = true) {
        self.inset = inset
    }

    public var body: some View {
        Divider()
            .padding(.leading, inset ? NimbusSyncDesignTokens.spacing16 + SettingsRowMetrics.tileSize + NimbusSyncDesignTokens.spacing12 : 0)
    }
}

/// A small rounded tile washed in the row's colour, holding its symbol — the Domains page's
/// logo pedestal at row size.
public struct SettingsIconTile: View {
    public let symbol: String
    public let tint: Color
    public let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    public init(symbol: String, tint: Color = NimbusSyncDesignTokens.brandTextColor, size: CGFloat = SettingsRowMetrics.tileSize) {
        self.symbol = symbol
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(tint.opacity(isEnabled ? 1 : 0.45))
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(tint.opacity(colorScheme == .dark ? 0.22 : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(tint.opacity(colorScheme == .dark ? 0.25 : 0.14))
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Page

/// The scrolling body under a Settings page header, with the Domains page's width and insets.
public struct SettingsPageBody<Content: View>: View {
    public let maxContentWidth: CGFloat
    public let horizontalInset: CGFloat
    @ViewBuilder let content: () -> Content

    public init(maxContentWidth: CGFloat, horizontalInset: CGFloat, @ViewBuilder content: @escaping () -> Content) {
        self.maxContentWidth = maxContentWidth
        self.horizontalInset = horizontalInset
        self.content = content
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content()
            }
            .frame(maxWidth: maxContentWidth, alignment: .leading)
            .padding(.horizontal, horizontalInset)
            .padding(.top, 4)
            .padding(.bottom, horizontalInset)
        }
    }
}

// MARK: - Small pieces

/// A capsule label such as "Version 0.1.0 (1)", in the status badge's shape.
public struct SettingsTagBadge: View {
    public let text: String
    public let tint: Color

    public init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(text)
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .textSelection(.enabled)
    }
}

/// The text for the About page's version badge: "Version 0.1.0 (1)", leaving out a build
/// number that is missing or the same as the version.
public enum SettingsAboutText {
    public static func version(short: String?, build: String?) -> String {
        let short = short?.trimmingCharacters(in: .whitespaces)
        let build = build?.trimmingCharacters(in: .whitespaces)
        guard let short, !short.isEmpty else {
            if let build, !build.isEmpty { return L10n.tr("Build \(build)") }
            return L10n.tr("Version unknown")
        }
        guard let build, !build.isEmpty, build != short else { return L10n.tr("Version \(short)") }
        return L10n.tr("Version \(short) (\(build))")
    }
}
