import SwiftUI
import CloudreveDomainKit

/// A Domain's connection to its Cloudreve server, as Settings shows it. Kept free of the event
/// module so the design system stays a leaf; the app maps its live-update state into this.
public struct ServerConnectionDisplay: Equatable, Sendable {
    public enum Kind: Sendable, Equatable {
        /// The live-update stream is subscribed.
        case connected
        case connecting
        /// The stream dropped; the app retries with backoff.
        case reconnecting
        case offline
        case authorizationRequired
        /// The app holds no stream for this Domain (removal, repair, missing credential, not started).
        case notConnected

        public var title: String {
            switch self {
            case .connected: "Connected"
            case .connecting: "Connecting…"
            case .reconnecting: "Reconnecting"
            case .offline: "Offline"
            case .authorizationRequired: "Authorization required"
            case .notConnected: "Not connected"
            }
        }

        public var symbol: String {
            switch self {
            case .connected: "checkmark.circle.fill"
            case .connecting, .reconnecting: "arrow.triangle.2.circlepath"
            case .offline: "wifi.slash"
            case .authorizationRequired: "person.crop.circle.badge.exclamationmark"
            case .notConnected: "pause.circle"
            }
        }

        public var tint: Color {
            switch self {
            case .connected: .green
            case .connecting: NimbusSyncDesignTokens.brandColor
            case .reconnecting, .authorizationRequired: .orange
            case .offline, .notConnected: .secondary
            }
        }
    }

    public let kind: Kind
    /// When the current state began; nil when unknown.
    public let since: Date?
    public let lastConnectedAt: Date?

    public init(kind: Kind, since: Date? = nil, lastConnectedAt: Date? = nil) {
        self.kind = kind
        self.since = since
        self.lastConnectedAt = lastConnectedAt
    }

    public static let notConnected = ServerConnectionDisplay(kind: .notConnected)

    /// One short line of timing context, or nil when there is nothing useful to say.
    public func detail(relativeTo now: Date = Date()) -> String? {
        switch kind {
        case .connected:
            guard let since else { return nil }
            return "Since \(CompactTimestamp.string(for: since, relativeTo: now))"
        case .connecting, .reconnecting, .offline, .authorizationRequired, .notConnected:
            guard let lastConnectedAt else { return nil }
            return "Last connected \(CompactTimestamp.string(for: lastConnectedAt, relativeTo: now))"
        }
    }
}

/// A compact colored dot plus label, for a Domain row.
public struct ServerConnectionIndicator: View {
    public let connection: ServerConnectionDisplay

    public init(connection: ServerConnectionDisplay) {
        self.connection = connection
    }

    public var body: some View {
        HStack(spacing: NimbusSyncDesignTokens.spacing4) {
            Circle()
                .fill(connection.kind.tint)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(connection.kind.title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Server connection: \(connection.kind.title)"))
    }
}

/// One Domain's server connection, for the Diagnostics page.
public struct ServerConnectionRow: View {
    public let displayName: String
    public let origin: String
    public let connection: ServerConnectionDisplay

    public init(displayName: String, origin: String, connection: ServerConnectionDisplay) {
        self.displayName = displayName
        self.origin = origin
        self.connection = connection
    }

    public var body: some View {
        HStack(alignment: .center, spacing: NimbusSyncDesignTokens.spacing12) {
            Image(systemName: connection.kind.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(connection.kind.tint)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(origin)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(origin)
            }

            Spacer(minLength: NimbusSyncDesignTokens.spacing12)

            VStack(alignment: .trailing, spacing: 2) {
                Text(connection.kind.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(connection.kind == .notConnected ? .secondary : connection.kind.tint)
                if let detail = connection.detail() {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Raw log lines as written, oldest first, in one compact monospaced block. It opens scrolled to
/// the newest line and follows new lines as they arrive.
public struct LogTextView: View {
    public let lines: [String]
    public let height: CGFloat

    public init(lines: [String], height: CGFloat = 260) {
        self.lines = lines
        self.height = height
    }

    /// Tabs separate the fields on disk; a pair of spaces keeps columns readable without wide gaps.
    static func displayText(_ lines: [String]) -> String {
        lines.map { $0.replacingOccurrences(of: "\t", with: "  ") }.joined(separator: "\n")
    }

    private static let bottomID = "log-bottom"

    public var body: some View {
        if lines.isEmpty {
            Text("No log entries yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Self.displayText(lines))
                            .font(.system(size: 11, design: .monospaced))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(NimbusSyncDesignTokens.spacing8)
                }
                .frame(height: height)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: NimbusSyncDesignTokens.cornerRadius))
                .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                .onChange(of: lines) { _ in proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
        }
    }
}

/// A thin bar plus one caption line for a Domain's running full check.
public struct DomainCheckProgressView: View {
    public let progress: DomainCheckProgress

    public init(progress: DomainCheckProgress) {
        self.progress = progress
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let fraction = progress.estimatedFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            Text(Self.summary(progress))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .controlSize(.small)
        .tint(NimbusSyncDesignTokens.brandColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Checking for updates"))
        .accessibilityValue(Text(Self.summary(progress)))
    }

    /// For example "Checking files · 1,234 of ~5,600 · 22%", or "Checking files · 1,234 items"
    /// when a first check has nothing to estimate against.
    public static func summary(_ progress: DomainCheckProgress) -> String {
        let phase = switch progress.phase {
        case .scanningFiles: "Checking files"
        case .scanningTrash: "Checking trash"
        case .applyingDeletions: "Finishing up"
        }
        let scanned = progress.scannedItems.formatted()
        guard let fraction = progress.estimatedFraction else { return "\(phase) · \(scanned) items" }
        let percent = Int((fraction * 100).rounded(.down))
        if progress.phase == .applyingDeletions { return "\(phase) · \(percent)%" }
        return "\(phase) · \(scanned) of ~\(progress.expectedItems.formatted()) · \(percent)%"
    }
}

public extension DomainCheckProgress {
    /// The progress to draw for a Domain, or nil when it is not checking or the check is too young.
    static func visible(for domain: DomainDescriptor, in progress: [String: DomainCheckProgress], at now: Date = Date()) -> DomainCheckProgress? {
        guard domain.status == .reconciling, let value = progress[domain.identifier], value.isWorthShowing(at: now) else { return nil }
        return value
    }
}
