import SwiftUI
import AppKit
import CloudreveDomainKit

public struct TaskDisplay: Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let progress: Double?
    public let detail: String
    public let state: String
    /// When the task last changed: its completion time once it is done.
    public let date: Date?
    /// The Domain the task belongs to, shown before the reason in the popover.
    public let domainName: String?
    /// False for work the app cannot start again itself, such as a download on a system that
    /// cannot be asked to download an item again.
    public let retryable: Bool

    public init(id: UUID, title: String, progress: Double?, detail: String, state: String, date: Date? = nil, domainName: String? = nil, retryable: Bool = true) {
        self.id = id
        self.title = title
        self.progress = progress
        self.detail = detail
        self.state = state
        self.date = date
        self.domainName = domainName
        self.retryable = retryable
    }

    /// A failed task, or one that needs the user before it can continue.
    public var isIssue: Bool { ["failed", "action_required"].contains(state.lowercased()) }
    /// A retry button that did nothing would be worse than none.
    /// Not offered for an item the server no longer has: that answer does not change on asking again.
    public var canRetry: Bool { retryable && state.canRetry && !Self.permanentReasons.contains(detail.lowercased()) }
    static let permanentReasons: Set<String> = ["not_found"]
    /// Any issue can be taken off the list, whether or not it can be retried.
    public var canClear: Bool { isIssue }
    public var canCancel: Bool { state.canCancel }

    /// Why the task stopped, or what it is doing, in words: "Network error", "Permission denied".
    public var reason: String { Self.reason(for: detail) }

    public static func reason(for code: String) -> String {
        if let title = SyncErrorText.title(for: code) { return title }
        return switch code.lowercased() {
        case "": ""
        case "queued": L10n.tr("Queued")
        case "running": L10n.tr("Syncing")
        case "retrying": L10n.tr("Retrying")
        case "succeeded": L10n.tr("Synced")
        case "failed": L10n.tr("Failed")
        case "cancelled": L10n.tr("Cancelled")
        default: {
            let words = code.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }()
        }
    }

    /// The popover row's second line, for example "data@cloud · Network error · 2 min. ago".
    public func activityCaption(relativeTo now: Date = Date()) -> String {
        [domainName, reason.isEmpty ? nil : reason, date.map { Self.relativeTime($0, relativeTo: now) }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    public static func relativeTime(_ date: Date, relativeTo now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return L10n.tr("Just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        // Match the app's own language rather than mixing in the system's.
        formatter.locale = L10n.locale
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// The row's second line, for example "14:32 · succeeded" or "Nov 7, 09:05 · failed".
    public func caption(relativeTo now: Date = Date()) -> String {
        Self.caption(detail: detail, date: date, relativeTo: now)
    }

    public static func caption(detail: String, date: Date?, relativeTo now: Date = Date()) -> String {
        [date.map { CompactTimestamp.string(for: $0, relativeTo: now) }, detail.isEmpty ? nil : detail]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// Time only for today, date and time otherwise.
public enum CompactTimestamp {
    public static func string(for date: Date, relativeTo now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale))
            : date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))
    }
}

/// Every Domain is a Cloudreve server, so each one wears Cloudreve's logo, drawn from the
/// bundle (see Scripts/make-domain-icon.swift): crisp at any size, offline, and never a
/// half-loaded site icon.
public struct DomainIconView: View {
    public let size: CGFloat

    public init(size: CGFloat = NimbusSyncDesignTokens.iconTileSize) {
        self.size = size
    }

    @MainActor public static let logo: NSImage? = Bundle.module.image(forResource: "CloudreveLogo")

    public var body: some View {
        Group {
            if let logo = Self.logo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: NimbusSyncDesignTokens.cornerRadius - 2)
                        .fill(NimbusSyncDesignTokens.brandColor.opacity(0.12))
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(NimbusSyncDesignTokens.brandColor)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// NimbusSync's own icon, for places that show the app rather than a Domain.
public struct AppIconView: View {
    public let size: CGFloat

    public init(size: CGFloat = NimbusSyncDesignTokens.iconTileSize) {
        self.size = size
    }

    /// The app bundles its icon rendered per appearance as `AppIconImage`, because
    /// `applicationIconImage` follows the system appearance and ignores the app's own Theme.
    private static let bundledImageName = "AppIconImage"
    private static let hasBundledImage = NSImage(named: bundledImageName) != nil

    public var body: some View {
        icon
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var icon: Image {
        Self.hasBundledImage
            ? Image(Self.bundledImageName, bundle: .main)
            : Image(nsImage: NSApplication.shared.applicationIconImage)
    }
}

public struct StatusBadge: View {
    @ObservedObject private var localization = AppLocalization.shared
    public let status: DomainStatus
    public let compact: Bool

    public init(status: DomainStatus, compact: Bool = false) {
        self.status = status
        self.compact = compact
    }

    public var body: some View {
        Label(compact ? status.shortTitle : status.title, systemImage: status.symbol)
            .font(compact ? .caption2.weight(.medium) : .caption.weight(.medium))
            .lineLimit(1)
            // A badge never wraps; the Domain name beside it truncates instead.
            .fixedSize()
            .foregroundStyle(status.tint)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 3 : 4)
            .background(status.tint.opacity(0.12), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(status.title))
            .help(status.title)
    }
}

public struct TaskProgressRow: View {
    @ObservedObject private var localization = AppLocalization.shared
    public let title: String
    public let progress: Double?
    public let detail: String
    public let state: String?
    public let date: Date?
    public let onCancel: (() -> Void)?
    public let onRetry: (() -> Void)?

    public init(
        title: String,
        progress: Double?,
        detail: String,
        state: String? = nil,
        date: Date? = nil,
        onCancel: (() -> Void)? = nil,
        onRetry: (() -> Void)? = nil
    ) {
        self.title = title
        self.progress = progress
        self.detail = detail
        self.state = state
        self.date = date
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
                    let caption = TaskDisplay.caption(detail: detail, date: date)
                    if !caption.isEmpty {
                        Text(caption)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(date.map { $0.formatted(Date.FormatStyle(date: .complete, time: .standard).locale(L10n.locale)) } ?? "")
                    }
                }

                Spacer(minLength: NimbusSyncDesignTokens.spacing8)

                if let state, state.canRetry {
                    Button(action: { onRetry?() }) {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: NimbusSyncDesignTokens.controlSize, height: NimbusSyncDesignTokens.controlSize)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.tr("Retry"))
                    .accessibilityLabel(Text(L10n.tr("Retry \(title)")))
                } else if let state, state.canCancel {
                    Button(action: { onCancel?() }) {
                        Image(systemName: "xmark.circle")
                            .frame(width: NimbusSyncDesignTokens.controlSize, height: NimbusSyncDesignTokens.controlSize)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.tr("Cancel"))
                    .accessibilityLabel(Text(L10n.tr("Cancel \(title)")))
                } else if let state {
                    Text(state.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(state.tint)
                }
            }

            if let progress {
                ProgressView(value: progress)
                    .tint(NimbusSyncDesignTokens.brandColor)
                    .accessibilityValue(Text(progress.formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale))))
            } else if state?.isInFlight == true {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(NimbusSyncDesignTokens.brandColor)
                    .accessibilityLabel(Text(L10n.tr("Working")))
            }
        }
        .padding(.vertical, NimbusSyncDesignTokens.spacing4)
    }
}

extension DomainStatus {
    var title: String {
        switch self {
        case .healthy: L10n.tr("Up to date")
        case .syncing: L10n.tr("Syncing")
        case .reconciling: L10n.tr("Checking for updates")
        case .offline: L10n.tr("Offline")
        case .eventDegraded: L10n.tr("Live updates unavailable")
        case .appNotRunning: L10n.tr("Live updates paused")
        case .authExpired: L10n.tr("Authorization required")
        case .rootUnavailable: L10n.tr("Remote root unavailable")
        case .scopeConflict: L10n.tr("Domain scope conflict")
        case .conflict: L10n.tr("Conflicts need attention")
        case .permanentError: L10n.tr("Action required")
        case .removalPreflight: L10n.tr("Removing")
        case .repairRequired: L10n.tr("Repair required")
        case .preservedRemoval: L10n.tr("Finish removal")
        default: L10n.tr("Preparing")
        }
    }

    /// For tight rows such as the popover's, where the Domain name must keep its room.
    var shortTitle: String {
        switch self {
        case .reconciling: L10n.tr("Checking")
        case .eventDegraded: L10n.tr("Live updates off")
        case .appNotRunning: L10n.tr("Paused")
        case .authExpired: L10n.tr("Sign in")
        case .rootUnavailable: L10n.tr("Root missing")
        case .scopeConflict: L10n.tr("Scope conflict")
        case .conflict: L10n.tr("Conflicts")
        case .repairRequired: L10n.tr("Repair")
        default: title
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

/// The file kind behind a row's tile, picked from the file extension.
public enum FileKindIcon: Equatable, Sendable {
    case pdf, image, video, audio, spreadsheet, presentation, document, archive, code, generic

    public init(fileName: String) {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "pdf": self = .pdf
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg", "raw", "dng": self = .image
        case "mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv": self = .video
        case "mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg": self = .audio
        case "xls", "xlsx", "csv", "tsv", "numbers": self = .spreadsheet
        case "ppt", "pptx", "key": self = .presentation
        case "doc", "docx", "pages", "txt", "md", "rtf", "odt": self = .document
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg": self = .archive
        case "swift", "js", "ts", "py", "go", "rs", "java", "json", "html", "css", "sh", "yml", "yaml": self = .code
        default: self = .generic
        }
    }

    var symbol: String {
        switch self {
        case .pdf: "doc.richtext.fill"
        case .image: "photo.fill"
        case .video: "play.fill"
        case .audio: "music.note"
        case .spreadsheet: "tablecells.fill"
        case .presentation: "rectangle.on.rectangle.angled.fill"
        case .document: "doc.text.fill"
        case .archive: "doc.zipper"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .generic: "doc.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pdf: .red
        case .image: Color(red: 0.2, green: 0.56, blue: 0.96)
        case .video: .purple
        case .audio: .pink
        case .spreadsheet: .green
        case .presentation: .orange
        case .document: NimbusSyncDesignTokens.brandColor
        case .archive: .brown
        case .code: .indigo
        case .generic: .gray
        }
    }
}

/// A coloured tile showing what kind of file a row is about.
public struct FileKindTile: View {
    public let fileName: String
    public let size: CGFloat

    public init(fileName: String, size: CGFloat = 30) {
        self.fileName = fileName
        self.size = size
    }

    public var body: some View {
        let kind = FileKindIcon(fileName: fileName)
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [kind.tint.opacity(0.82), kind.tint], startPoint: .top, endPoint: .bottom))
            .overlay {
                Image(systemName: kind.symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private extension String {
    var isInFlight: Bool { ["queued", "running", "retrying"].contains(lowercased()) }
    var canCancel: Bool { ["queued", "running", "retrying"].contains(lowercased()) }
    var canRetry: Bool { ["retrying", "failed"].contains(lowercased()) }

    var title: String {
        switch lowercased() {
        case "queued": L10n.tr("Queued")
        case "running": L10n.tr("Syncing")
        case "retrying": L10n.tr("Retrying")
        case "succeeded": L10n.tr("Completed")
        case "failed", "action_required": L10n.tr("Needs attention")
        case "cancelled": L10n.tr("Cancelled")
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
