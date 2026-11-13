import SwiftUI
import AppKit
import CloudreveDomainKit

public struct MenuBarPopoverView: View {
    public let domains: [DomainDescriptor]
    public let tasks: [TaskDisplay]
    public let recentTasks: [TaskDisplay]
    public let hasActionableConflicts: Bool
    public let onOpenSettings: () -> Void
    public let onAddDomain: () -> Void
    public let onOpenConflicts: () -> Void
    public let onOpenDomain: (DomainDescriptor) -> Void
    public let onCancelTask: (UUID) -> Void
    public let onRetryTask: (UUID) -> Void
    /// Takes an issue off the list.
    public let onClearTask: (UUID) -> Void
    /// Server connection per Domain identifier; a Domain without an entry shows no indicator.
    public let connections: [String: ServerConnectionDisplay]
    /// Running full checks per Domain identifier.
    public let checkProgress: [String: DomainCheckProgress]
    /// Domains that can start a full check now; nil hides the action.
    public let checkableDomainIdentifiers: Set<String>
    public let onCheckDomain: ((DomainDescriptor) -> Void)?
    /// nil hides the Quit button.
    public let onQuit: (() -> Void)?
    /// Finder integration is switched off in System Settings, so nothing can sync.
    public let finderIntegrationOff: Bool
    public let onOpenFinderIntegrationSettings: () -> Void
    /// The scrolling content's natural height. The menu bar window sizes itself to the smallest
    /// height the popover accepts, and a flexible ScrollView accepts zero, so the scroll area
    /// is pinned to this measured height instead (capped, and scrolling beyond the cap).
    @State private var contentHeight: CGFloat = 0
    /// nil follows the content: Issues while there are any, All otherwise.
    @State private var activityFilter: ActivityFilter?
    @State private var showsAllActivity = false
    /// Issues cleared here, hidden at once rather than after the store catches up. An ID leaves
    /// once the tasks passed in no longer carry it, so a task that comes back is shown again.
    @State private var clearedTaskIDs: Set<UUID> = []
    static let maximumContentHeight: CGFloat = 500
    /// Activity rows shown before "Show N more".
    static let activityRowLimit = 5

    enum ActivityFilter: Hashable {
        case issues, all
    }

    public init(
        domains: [DomainDescriptor],
        tasks: [TaskDisplay] = [],
        recentTasks: [TaskDisplay] = [],
        hasActionableConflicts: Bool = false,
        onOpenSettings: @escaping () -> Void = {},
        onAddDomain: @escaping () -> Void = {},
        onOpenConflicts: @escaping () -> Void = {},
        onOpenDomain: @escaping (DomainDescriptor) -> Void = { _ in },
        onCancelTask: @escaping (UUID) -> Void = { _ in },
        onRetryTask: @escaping (UUID) -> Void = { _ in },
        onClearTask: @escaping (UUID) -> Void = { _ in },
        connections: [String: ServerConnectionDisplay] = [:],
        checkProgress: [String: DomainCheckProgress] = [:],
        checkableDomainIdentifiers: Set<String> = [],
        onCheckDomain: ((DomainDescriptor) -> Void)? = nil,
        onQuit: (() -> Void)? = nil,
        finderIntegrationOff: Bool = false,
        onOpenFinderIntegrationSettings: @escaping () -> Void = {}
    ) {
        self.domains = domains
        self.tasks = tasks
        self.recentTasks = recentTasks
        self.hasActionableConflicts = hasActionableConflicts
        self.onOpenSettings = onOpenSettings
        self.onAddDomain = onAddDomain
        self.onOpenConflicts = onOpenConflicts
        self.onOpenDomain = onOpenDomain
        self.onCancelTask = onCancelTask
        self.onRetryTask = onRetryTask
        self.onClearTask = onClearTask
        self.connections = connections
        self.checkProgress = checkProgress
        self.checkableDomainIdentifiers = checkableDomainIdentifiers
        self.onCheckDomain = onCheckDomain
        self.onQuit = onQuit
        self.finderIntegrationOff = finderIntegrationOff
        self.onOpenFinderIntegrationSettings = onOpenFinderIntegrationSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: NimbusSyncDesignTokens.spacing16) {
                    if finderIntegrationOff {
                        finderIntegrationBanner
                    }

                    if !issues.isEmpty {
                        issueBanner
                    }

                    if hasActionableConflicts {
                        conflictBanner
                    }

                    if domains.isEmpty {
                        emptyState
                    } else {
                        domainsSection
                    }

                    if !allActivity.isEmpty {
                        activitySection
                    }
                }
                .padding(.horizontal, NimbusSyncDesignTokens.spacing16)
                .padding(.top, NimbusSyncDesignTokens.spacing4)
                .padding(.bottom, NimbusSyncDesignTokens.spacing16)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
            }
            .frame(height: min(contentHeight, Self.maximumContentHeight))

            Divider()
                .padding(.horizontal, NimbusSyncDesignTokens.spacing16)
            footer
        }
        .frame(minWidth: 380, idealWidth: NimbusSyncDesignTokens.popoverWidth, maxWidth: 420)
        .tint(NimbusSyncDesignTokens.brandColor)
        .onChange(of: Set((tasks + recentTasks).map(\.id))) { ids in
            clearedTaskIDs.formIntersection(ids)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: NimbusSyncDesignTokens.spacing12) {
            AppIconView(size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(AppIdentity.displayName)
                    .font(.title3.weight(.semibold))
                Text(summary.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: NimbusSyncDesignTokens.spacing8)

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            .buttonStyle(PopoverIconButtonStyle(size: 30))
            .accessibilityLabel(Text("Settings"))
        }
        .padding(.horizontal, NimbusSyncDesignTokens.spacing16)
        .padding(.top, NimbusSyncDesignTokens.spacing16)
        .padding(.bottom, NimbusSyncDesignTokens.spacing12)
    }

    // MARK: Banners

    private var finderIntegrationBanner: some View {
        PopoverBanner(
            symbol: "pause.circle.fill",
            title: FinderIntegrationGuideText.offHeadline,
            detail: FinderIntegrationGuideText.bannerDetail,
            actionTitle: "Turn On",
            action: onOpenFinderIntegrationSettings,
            actionSymbol: "arrow.up.forward.app"
        )
    }

    private var issueBanner: some View {
        let retryable = issues.filter(\.canRetry)
        return PopoverBanner(
            symbol: "exclamationmark.triangle.fill",
            title: Self.issueTitle(count: issues.count),
            detail: Self.issueDetail(issues),
            actionTitle: retryable.isEmpty ? nil : (retryable.count == 1 ? "Retry" : "Retry All"),
            action: { retryable.forEach { onRetryTask($0.id) } }
        )
    }

    private var conflictBanner: some View {
        PopoverBanner(
            symbol: "exclamationmark.2",
            title: "Conflicts need attention",
            detail: "Review the latest local and remote versions.",
            actionTitle: "Review",
            action: onOpenConflicts,
            actionSymbol: "arrow.right"
        )
    }

    static func issueTitle(count: Int) -> String {
        "\(count) file\(count == 1 ? "" : "s") couldn't sync"
    }

    /// "data@cloud · Network error" when every issue shares a Domain and a reason.
    static func issueDetail(_ issues: [TaskDisplay]) -> String {
        let domainNames = Set(issues.compactMap(\.domainName))
        let reasons = Set(issues.map(\.reason).filter { !$0.isEmpty })
        let domainPart: String? = switch domainNames.count {
        case 0: nil
        case 1: domainNames.first
        default: "\(domainNames.count) domains"
        }
        let reasonPart: String? = reasons.count == 1 ? reasons.first : (reasons.isEmpty ? nil : "Several reasons")
        return [domainPart, reasonPart].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Domains

    private var domainsSection: some View {
        VStack(alignment: .leading, spacing: NimbusSyncDesignTokens.spacing8) {
            sectionHeading("Domains") {
                Text("\(domains.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("\(domains.count) domains"))
            }
            PopoverCard {
                ForEach(domains, id: \.identifier) { domain in
                    domainRow(domain)
                    if domain.identifier != domains.last?.identifier {
                        Divider().padding(.leading, NimbusSyncDesignTokens.spacing12)
                    }
                }
            }
        }
    }

    private func domainRow(_ domain: DomainDescriptor) -> some View {
        let progress = DomainCheckProgress.visible(for: domain, in: checkProgress)
        return VStack(alignment: .leading, spacing: NimbusSyncDesignTokens.spacing8) {
            HStack(spacing: NimbusSyncDesignTokens.spacing12) {
                DomainIconView(size: 34)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: NimbusSyncDesignTokens.spacing8) {
                        Text(domain.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        StatusBadge(status: domain.status, compact: true)
                    }
                    if progress == nil {
                        HStack(spacing: NimbusSyncDesignTokens.spacing8) {
                            if let connection = connections[domain.identifier] {
                                ServerConnectionIndicator(connection: connection)
                                    .fixedSize()
                            }
                            Text(Self.host(of: domain))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(domain.scope.origin)
                        }
                    }
                }

                Spacer(minLength: NimbusSyncDesignTokens.spacing4)

                HStack(spacing: 6) {
                    Button(action: { onOpenDomain(domain) }) {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(PopoverIconButtonStyle())
                    .accessibilityLabel(Text("Open \(domain.displayName) in Finder"))
                    .help("Open in Finder")

                    if let onCheckDomain {
                        Button(action: { onCheckDomain(domain) }) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(PopoverIconButtonStyle())
                        .disabled(!checkableDomainIdentifiers.contains(domain.identifier))
                        .accessibilityLabel(Text("Check \(domain.displayName) now"))
                        .help("Check Now: compare every file with the server")
                    }
                }
            }

            if let progress {
                PopoverCheckProgressView(progress: progress)
            }
        }
        .padding(NimbusSyncDesignTokens.spacing12)
    }

    static func host(of domain: DomainDescriptor) -> String {
        URL(string: domain.scope.origin)?.host ?? domain.scope.origin
    }

    private var emptyState: some View {
        PopoverCard {
            VStack(spacing: NimbusSyncDesignTokens.spacing8) {
                Image(systemName: "externaldrive.badge.plus")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(NimbusSyncDesignTokens.brandColor)
                    .accessibilityHidden(true)
                Text("Connect your first domain")
                    .font(.headline)
                Text("Add a Cloudreve domain to make it available in Finder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onAddDomain) {
                    Label("Add Domain", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, NimbusSyncDesignTokens.spacing20)
            .padding(.horizontal, NimbusSyncDesignTokens.spacing16)
        }
    }

    // MARK: Activity

    /// Active tasks first, then the rest, newest first.
    private var allActivity: [TaskDisplay] {
        (tasks + recentTasks.filter { recent in !tasks.contains { $0.id == recent.id } })
            .filter { !clearedTaskIDs.contains($0.id) }
    }

    private var issues: [TaskDisplay] {
        allActivity.filter(\.isIssue)
    }

    private var effectiveFilter: ActivityFilter {
        activityFilter ?? (issues.isEmpty ? .all : .issues)
    }

    /// Clears the given issues; once none are left the list moves to All rather than sitting on
    /// an empty Issues tab.
    private func clearIssues(_ ids: [UUID]) {
        let remaining = issues.filter { !ids.contains($0.id) }
        clearedTaskIDs.formUnion(ids)
        ids.forEach(onClearTask)
        if remaining.isEmpty {
            activityFilter = .all
            showsAllActivity = false
        }
    }

    private var activitySection: some View {
        let rows = effectiveFilter == .issues ? issues : allActivity
        let visible = showsAllActivity ? rows : Array(rows.prefix(Self.activityRowLimit))
        let hidden = rows.count - visible.count
        return VStack(alignment: .leading, spacing: NimbusSyncDesignTokens.spacing8) {
            sectionHeading("Activity") {
                PopoverSegmentedControl(
                    selection: Binding(get: { effectiveFilter }, set: { activityFilter = $0 }),
                    segments: [
                        (ActivityFilter.issues, issues.isEmpty ? "Issues" : "Issues \(issues.count)"),
                        (ActivityFilter.all, "All"),
                    ]
                )
            }

            PopoverCard {
                if rows.isEmpty {
                    HStack(spacing: NimbusSyncDesignTokens.spacing8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("No issues")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(NimbusSyncDesignTokens.spacing12)
                } else {
                    ForEach(Self.groupedByDay(visible), id: \.title) { group in
                        dayHeader(group.title)
                        ForEach(group.tasks) { task in
                            activityRow(task)
                            if task.id != group.tasks.last?.id {
                                Divider().padding(.leading, 54)
                            }
                        }
                    }
                    if hidden > 0 || showsAllActivity && rows.count > Self.activityRowLimit {
                        Divider()
                        Button(hidden > 0 ? "Show \(hidden) more" : "Show less") {
                            showsAllActivity.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(NimbusSyncDesignTokens.brandColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, NimbusSyncDesignTokens.spacing8)
                    }
                    if effectiveFilter == .issues {
                        Divider()
                        issueActions
                    }
                }
            }
        }
    }

    /// Retry All and Clear All under the Issues list; they act on every issue, not only the
    /// rows shown.
    private var issueActions: some View {
        let retryable = issues.filter(\.canRetry)
        return HStack(spacing: 0) {
            if !retryable.isEmpty {
                Button(action: { retryable.forEach { onRetryTask($0.id) } }) {
                    Label("Retry All", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .help("Retry every issue that can be retried")
                Divider().frame(height: 14)
            }
            Button(action: { clearIssues(issues.map(\.id)) }) {
                Label("Clear All", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .help("Remove every issue from this list")
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(NimbusSyncDesignTokens.brandColor)
        .padding(.vertical, NimbusSyncDesignTokens.spacing8)
    }

    private func dayHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, NimbusSyncDesignTokens.spacing12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04))
            .accessibilityAddTraits(.isHeader)
    }

    private func activityRow(_ task: TaskDisplay) -> some View {
        HStack(spacing: NimbusSyncDesignTokens.spacing12) {
            FileKindTile(fileName: task.title, size: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(task.title)
                Text(task.activityCaption())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(task.date.map { $0.formatted(date: .complete, time: .standard) } ?? "")
                if let progress = task.progress, task.canCancel {
                    PopoverProgressBar(fraction: progress)
                        .padding(.top, 2)
                        .accessibilityValue(Text("\(Int(progress * 100)) percent"))
                }
            }

            Spacer(minLength: NimbusSyncDesignTokens.spacing4)

            if task.canRetry || task.canClear {
                HStack(spacing: 6) {
                    if task.canRetry {
                        Button(action: { onRetryTask(task.id) }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(PopoverIconButtonStyle())
                        .help("Retry")
                        .accessibilityLabel(Text("Retry \(task.title)"))
                    }
                    if task.canClear {
                        Button(action: { clearIssues([task.id]) }) {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(PopoverIconButtonStyle())
                        .help("Clear")
                        .accessibilityLabel(Text("Clear \(task.title)"))
                    }
                }
            } else if task.canCancel {
                Button(action: { onCancelTask(task.id) }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(PopoverIconButtonStyle())
                .help("Cancel")
                .accessibilityLabel(Text("Cancel \(task.title)"))
            } else if task.state.lowercased() == "succeeded" {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel(Text("Synced"))
            }
        }
        .padding(.horizontal, NimbusSyncDesignTokens.spacing12)
        .padding(.vertical, 9)
    }

    struct DayGroup {
        let title: String
        let tasks: [TaskDisplay]
    }

    /// Consecutive rows grouped under Today, Yesterday or Earlier, keeping their order.
    static func groupedByDay(_ tasks: [TaskDisplay], now: Date = Date(), calendar: Calendar = .current) -> [DayGroup] {
        var groups: [DayGroup] = []
        for task in tasks {
            let title: String
            if let date = task.date, calendar.isDate(date, inSameDayAs: now) {
                title = "Today"
            } else if let date = task.date, calendar.isDateInYesterday(date) {
                title = "Yesterday"
            } else {
                title = "Earlier"
            }
            if let last = groups.last, last.title == title {
                groups[groups.count - 1] = DayGroup(title: title, tasks: last.tasks + [task])
            } else if let index = groups.firstIndex(where: { $0.title == title }) {
                groups[index] = DayGroup(title: title, tasks: groups[index].tasks + [task])
            } else {
                groups.append(DayGroup(title: title, tasks: [task]))
            }
        }
        return groups
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: NimbusSyncDesignTokens.spacing12) {
            Button(action: onAddDomain) {
                Label("Add Domain", systemImage: "plus")
            }
            .buttonStyle(.plain)

            Spacer()

            Button("Settings…", action: onOpenSettings)
                .help("Open Settings")
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(",", modifiers: .command)

            if let onQuit {
                Divider().frame(height: 14)
                Button("Quit", action: onQuit)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("q", modifiers: .command)
                    .accessibilityLabel(Text("Quit \(AppIdentity.displayName)"))
                    .help("Quit \(AppIdentity.displayName)")
            }
        }
        .font(.callout)
        .padding(.horizontal, NimbusSyncDesignTokens.spacing16)
        .padding(.vertical, NimbusSyncDesignTokens.spacing12)
    }

    // MARK: Shared pieces

    private func sectionHeading<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: NimbusSyncDesignTokens.spacing8)
            trailing()
        }
        .padding(.horizontal, 2)
    }

    private var summary: MenuBarStatusSummary {
        MenuBarStatusSummary(domains: domains, activeTaskCount: tasks.count, hasActionableConflicts: hasActionableConflicts, finderIntegrationOff: finderIntegrationOff)
    }
}

/// The popover's version of a running full check: what it is doing on the left, how far and how
/// long on the right, and a bar underneath.
struct PopoverCheckProgressView: View {
    let progress: DomainCheckProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: NimbusSyncDesignTokens.spacing8) {
                Text(PopoverCheckProgressText.activity(progress))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: NimbusSyncDesignTokens.spacing4)
                if let trailing = PopoverCheckProgressText.estimate(progress) {
                    Text(trailing)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            if let fraction = progress.estimatedFraction {
                PopoverProgressBar(fraction: fraction)
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

public enum PopoverCheckProgressText {
    /// "Checking files — 61,223 of about 150,200", or "Checking files — 42 items" on a first check.
    public static func activity(_ progress: DomainCheckProgress) -> String {
        switch progress.phase {
        case .applyingDeletions:
            return "Finishing up"
        case .scanningFiles, .scanningTrash:
            let phase = progress.phase == .scanningFiles ? "Checking files" : "Checking trash"
            let scanned = progress.scannedItems.formatted()
            guard progress.estimatedFraction != nil else { return "\(phase) — \(scanned) items" }
            return "\(phase) — \(scanned) of about \(progress.expectedItems.formatted())"
        }
    }

    /// "40% · about 3 min left", "40%" until a time estimate means something, nil without a total.
    public static func estimate(_ progress: DomainCheckProgress, now: Date = Date()) -> String? {
        guard let fraction = progress.estimatedFraction else { return nil }
        let percent = "\(Int((fraction * 100).rounded(.down)))%"
        guard let remaining = remainingTime(progress, now: now) else { return percent }
        return "\(percent) · \(remaining)"
    }

    static func remainingTime(_ progress: DomainCheckProgress, now: Date) -> String? {
        guard progress.phase == .scanningFiles, let fraction = progress.estimatedFraction, fraction >= 0.03, fraction < 0.99 else { return nil }
        let elapsed = now.timeIntervalSince(progress.startedAt)
        guard elapsed >= 10 else { return nil }
        let seconds = elapsed * (1 - fraction) / fraction
        if seconds < 60 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 90 { return "about \(minutes) min left" }
        let hours = Int((seconds / 3600).rounded())
        return "about \(hours) hr left"
    }
}

/// Fills for things drawn on the popover. The menu bar window is a translucent material whose
/// colour follows the wallpaper behind it, so an opaque fill (controlBackgroundColor) reads as a
/// light slab on a grey panel. These are thin white veils over the panel instead: they lift a
/// surface a little above whatever the panel happens to be, in either appearance.
enum PopoverSurface {
    /// Cards: one step above the panel.
    static func card(_ scheme: ColorScheme) -> Color {
        .white.opacity(scheme == .dark ? 0.05 : 0.16)
    }

    /// A chosen segment: about as bright as a card, so it reads as the same material.
    static func raised(_ scheme: ColorScheme) -> Color {
        .white.opacity(scheme == .dark ? 0.12 : 0.22)
    }

    /// Hairline edges, which carry the separation the fills no longer shout.
    static func edge(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.09) : .black.opacity(0.07)
    }
}

/// Two or three choices in a soft track; the chosen one sits on a raised chip.
struct PopoverSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let segments: [(Value, String)]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments, id: \.0) { value, title in
                let isSelected = value == selection
                Button(action: { selection = value }) {
                    Text(title)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(PopoverSurface.raised(colorScheme))
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(PopoverSurface.edge(colorScheme))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .fixedSize()
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

/// A slim determinate bar in the brand colour.
struct PopoverProgressBar: View {
    let fraction: Double
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(NimbusSyncDesignTokens.brandColor)
                    .frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A rounded, lightly raised group of rows.
struct PopoverCard<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: NimbusSyncDesignTokens.popoverCardRadius, style: .continuous)
                .fill(PopoverSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: NimbusSyncDesignTokens.popoverCardRadius, style: .continuous)
                .strokeBorder(PopoverSurface.edge(colorScheme))
        )
        .clipShape(RoundedRectangle(cornerRadius: NimbusSyncDesignTokens.popoverCardRadius, style: .continuous))
    }
}

/// A tinted callout with one action on the right.
struct PopoverBanner: View {
    let symbol: String
    let title: String
    let detail: String
    let actionTitle: String?
    let action: () -> Void
    var actionSymbol = "arrow.clockwise"
    var tint: Color = .orange

    var body: some View {
        HStack(spacing: NimbusSyncDesignTokens.spacing12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: NimbusSyncDesignTokens.spacing8)

            if let actionTitle {
                Button(action: action) {
                    HStack(spacing: 5) {
                        Image(systemName: actionSymbol)
                            .foregroundStyle(tint)
                            .accessibilityHidden(true)
                        Text(actionTitle)
                    }
                }
                .buttonStyle(PopoverBannerButtonStyle())
            }
        }
        .padding(NimbusSyncDesignTokens.spacing12)
        .background(
            RoundedRectangle(cornerRadius: NimbusSyncDesignTokens.popoverCardRadius, style: .continuous)
                .fill(tint.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: NimbusSyncDesignTokens.popoverCardRadius, style: .continuous)
                .strokeBorder(tint.opacity(0.3))
        )
    }
}

/// The banner's action wears the same soft fill as the row buttons; only its glyph carries the
/// banner's tint, so it is findable without a solid block of colour on a translucent panel.
struct PopoverBannerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BannerButton(configuration: configuration)
    }

    private struct BannerButton: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.primary.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : (isHovered ? 0.11 : 0.07)))
                )
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }
}

/// A square, softly filled icon button, as used for row actions in the popover.
struct PopoverIconButtonStyle: ButtonStyle {
    var size: CGFloat = NimbusSyncDesignTokens.controlSize

    func makeBody(configuration: Configuration) -> some View {
        PopoverIconButton(configuration: configuration, size: size)
    }

    private struct PopoverIconButton: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(Color.primary.opacity(isEnabled ? 0.75 : 0.3))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                        .fill(Color.primary.opacity(fillOpacity))
                )
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }

        private var fillOpacity: Double {
            guard isEnabled else { return 0.04 }
            if configuration.isPressed { return 0.16 }
            return isHovered ? 0.11 : 0.07
        }
    }
}
