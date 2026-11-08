import SwiftUI
import CloudreveDomainKit

public struct TaskDisplay: Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let progress: Double?
    public let detail: String
    public let state: String

    public init(id: UUID, title: String, progress: Double?, detail: String, state: String) {
        self.id = id
        self.title = title
        self.progress = progress
        self.detail = detail
        self.state = state
    }
}

public struct DomainIconView: View {
    public let iconURL: URL?
    public let size: CGFloat

    public init(iconURL: URL?, size: CGFloat = NimbusSyncDesignTokens.iconTileSize) {
        self.iconURL = iconURL
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: NimbusSyncDesignTokens.cornerRadius - 2)
                .fill(NimbusSyncDesignTokens.brandColor.opacity(0.12))
            if let iconURL {
                AsyncImage(url: iconURL) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFit().padding(size * 0.2)
                    } else {
                        fallbackIcon
                    }
                }
            } else {
                fallbackIcon
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var fallbackIcon: some View {
        Image(systemName: "externaldrive.fill")
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(NimbusSyncDesignTokens.brandColor)
    }
}

public struct StatusBadge: View {
    public let status: DomainStatus
    public let compact: Bool

    public init(status: DomainStatus, compact: Bool = false) {
        self.status = status
        self.compact = compact
    }

    public var body: some View {
        Label(status.title, systemImage: status.symbol)
            .font(compact ? .caption2.weight(.medium) : .caption.weight(.medium))
            .foregroundStyle(status.tint)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 3 : 4)
            .background(status.tint.opacity(0.12), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(status.title))
    }
}

public struct TaskProgressRow: View {
    public let title: String
    public let progress: Double?
    public let detail: String
    public let state: String?
    public let onCancel: (() -> Void)?
    public let onRetry: (() -> Void)?

    public init(
        title: String,
        progress: Double?,
        detail: String,
        state: String? = nil,
        onCancel: (() -> Void)? = nil,
        onRetry: (() -> Void)? = nil
    ) {
        self.title = title
        self.progress = progress
        self.detail = detail
        self.state = state
        self.onCancel = onCancel
        self.onRetry = onRetry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NimbusSyncDesignTokens.spacing8) {
            HStack(alignment: .top, spacing: NimbusSyncDesignTokens.spacing8) {
                Image(systemName: state?.symbol ?? "doc")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(state?.tint ?? .secondary)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: NimbusSyncDesignTokens.spacing4) {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(title)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: NimbusSyncDesignTokens.spacing8)

                if let state, state.canRetry {
                    Button(action: { onRetry?() }) {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: NimbusSyncDesignTokens.controlSize, height: NimbusSyncDesignTokens.controlSize)
                    }
                    .buttonStyle(.borderless)
                    .help("Retry")
                    .accessibilityLabel(Text("Retry \(title)"))
                } else if let state, state.canCancel {
                    Button(action: { onCancel?() }) {
                        Image(systemName: "xmark.circle")
                            .frame(width: NimbusSyncDesignTokens.controlSize, height: NimbusSyncDesignTokens.controlSize)
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel")
                    .accessibilityLabel(Text("Cancel \(title)"))
                } else if let state {
                    Text(state.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(state.tint)
                }
            }

            if let progress {
                ProgressView(value: progress)
                    .tint(NimbusSyncDesignTokens.brandColor)
                    .accessibilityValue(Text("\(Int(progress * 100)) percent"))
            } else if state?.isInFlight == true {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(NimbusSyncDesignTokens.brandColor)
                    .accessibilityLabel(Text("Working"))
            }
        }
        .padding(.vertical, NimbusSyncDesignTokens.spacing4)
    }
}

extension DomainStatus {
    var title: String {
        switch self {
        case .healthy: "Up to date"
        case .syncing: "Syncing"
        case .reconciling: "Checking for updates"
        case .offline: "Offline"
        case .eventDegraded: "Live updates unavailable"
        case .appNotRunning: "Live updates paused"
        case .authExpired: "Authorization required"
        case .rootUnavailable: "Remote root unavailable"
        case .scopeConflict: "Domain scope conflict"
        case .conflict: "Conflicts need attention"
        case .permanentError: "Action required"
        case .removalPreflight: "Removing"
        case .repairRequired: "Repair required"
        case .preservedRemoval: "Finish removal"
        default: "Preparing"
        }
    }

    var symbol: String {
        switch self {
        case .healthy: "checkmark.circle"
        case .offline: "wifi.slash"
        case .authExpired: "person.crop.circle.badge.exclamationmark"
        case .conflict: "exclamationmark.triangle"
        case .removalPreflight: "trash"
        case .repairRequired: "wrench.and.screwdriver"
        case .preservedRemoval: "externaldrive.badge.xmark"
        default: "arrow.triangle.2.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .healthy: .green
        case .authExpired, .conflict, .permanentError, .rootUnavailable, .scopeConflict, .repairRequired, .preservedRemoval: .orange
        case .offline: .secondary
        default: .accentColor
        }
    }

    var priority: Int {
        switch self {
        case .authExpired: 100
        case .rootUnavailable, .scopeConflict, .repairRequired, .preservedRemoval: 90
        case .conflict, .permanentError: 80
        case .offline: 70
        case .reconciling: 60
        case .syncing: 50
        case .eventDegraded, .appNotRunning: 40
        case .healthy: 10
        default: 0
        }
    }
}

private extension String {
    var isInFlight: Bool { ["queued", "running", "retrying"].contains(lowercased()) }
    var canCancel: Bool { ["queued", "running", "retrying"].contains(lowercased()) }
    var canRetry: Bool { ["retrying", "failed"].contains(lowercased()) }

    var title: String {
        switch lowercased() {
        case "queued": "Queued"
        case "running": "Syncing"
        case "retrying": "Retrying"
        case "succeeded": "Completed"
        case "failed", "action_required": "Needs attention"
        case "cancelled": "Cancelled"
        default: capitalized
        }
    }

    var symbol: String {
        switch lowercased() {
        case "queued": "clock"
        case "running": "arrow.triangle.2.circlepath"
        case "retrying": "arrow.clockwise"
        case "succeeded": "checkmark.circle.fill"
        case "failed", "action_required": "exclamationmark.triangle.fill"
        case "cancelled": "xmark.circle"
        default: "doc"
        }
    }

    var tint: Color {
        switch lowercased() {
        case "succeeded": .green
        case "failed", "action_required": .orange
        case "cancelled": .secondary
        default: NimbusSyncDesignTokens.brandColor
        }
    }
}

/// One activity-log line as the popover shows it. Kept free of the logging module so the design
/// system stays a leaf; the app maps its log entries into these.
public struct LogEntryDisplay: Identifiable, Sendable, Equatable {
    public enum Level: Sendable, Equatable {
        case info, warning, error

        var symbol: String {
            switch self {
            case .info: "info.circle"
            case .warning: "exclamationmark.triangle"
            case .error: "xmark.octagon"
            }
        }

        var tint: Color {
            switch self {
            case .info: .secondary
            case .warning: .orange
            case .error: .red
            }
        }

        var accessibilityName: String {
            switch self {
            case .info: "Info"
            case .warning: "Warning"
            case .error: "Error"
            }
        }
    }

    public let id: String
    public let date: Date
    public let level: Level
    /// `app` or `fileprovider`.
    public let source: String
    public let category: String
    public let message: String

    public init(id: String, date: Date, level: Level, source: String, category: String, message: String) {
        self.id = id; self.date = date; self.level = level; self.source = source; self.category = category; self.message = message
    }
}

struct LogEntryRow: View {
    let entry: LogEntryDisplay

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NimbusSyncDesignTokens.spacing8) {
            Image(systemName: entry.level.symbol)
                .font(.caption)
                .foregroundStyle(entry.level.tint)
                .accessibilityLabel(Text(entry.level.accessibilityName))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .help(entry.message)
                Text("\(entry.date.formatted(date: .omitted, time: .standard)) · \(entry.source == "fileprovider" ? "Finder extension" : "App") · \(entry.category)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
