import SwiftUI
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
    /// Server connection per Domain identifier; a Domain without an entry shows no indicator.
    public let connections: [String: ServerConnectionDisplay]
    /// Running full checks per Domain identifier.
    public let checkProgress: [String: DomainCheckProgress]
    /// Domains that can start a full check now; nil hides the action.
    public let checkableDomainIdentifiers: Set<String>
    public let onCheckDomain: ((DomainDescriptor) -> Void)?
    /// The scrolling content's natural height. The menu bar window sizes itself to the smallest
    /// height the popover accepts, and a flexible ScrollView accepts zero, so the scroll area
    /// is pinned to this measured height instead (capped, and scrolling beyond the cap).
    @State private var contentHeight: CGFloat = 0
    static let maximumContentHeight: CGFloat = 520

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
        connections: [String: ServerConnectionDisplay] = [:],
        checkProgress: [String: DomainCheckProgress] = [:],
        checkableDomainIdentifiers: Set<String> = [],
        onCheckDomain: ((DomainDescriptor) -> Void)? = nil
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
        self.connections = connections
        self.checkProgress = checkProgress
        self.checkableDomainIdentifiers = checkableDomainIdentifiers
        self.onCheckDomain = onCheckDomain
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: NimbusSyncDesignTokens.spacing16) {
                    statusOverview

                    if domains.isEmpty {
                        emptyState
                    } else {
                        domainsSection
                    }

                    if hasActionableConflicts {
                        conflictCallout
                    }

                    if !tasks.isEmpty {
                        taskSection(title: "Active tasks", tasks: tasks)
                    }

                    if !recentTasks.isEmpty {
                        taskSection(title: "Recent activity", tasks: recentTasks)
                    }
                }
                .padding(.horizontal, NimbusSyncDesignTokens.spacing16)
                .padding(.vertical, NimbusSyncDesignTokens.spacing16)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
            }
            .frame(height: min(contentHeight, Self.maximumContentHeight))
        }
        .frame(minWidth: 380, idealWidth: NimbusSyncDesignTokens.popoverWidth, maxWidth: 420)
        .tint(NimbusSyncDesignTokens.brandColor)
    }

    private var header: some View {
        HStack(spacing: NimbusSyncDesignTokens.spacing12) {
            DomainIconView(iconURL: nil, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("NimbusSync")
                    .font(.headline)
                Text("Cloudreve for Finder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: NimbusSyncDesignTokens.spacing8)

            HStack(spacing: NimbusSyncDesignTokens.spacing4) {
                settingsButton

                Button(action: onAddDomain) {
                    Image(systemName: "plus")
                        .frame(width: NimbusSyncDesignTokens.controlSize, height: NimbusSyncDesignTokens.controlSize)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Add domain"))
                .help("Add domain")
            }
        }
        .padding(.horizontal, NimbusSyncDesignTokens.spacing16)
        .padding(.vertical, NimbusSyncDesignTokens.spacing12)
    }

    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                settingsButtonLabel
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Settings"))
            .help("Settings")
        } else {
            Button(action: onOpenSettings) {
                settingsButtonLabel
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Settings"))
            .help("Settings")
        }
    }

    private var settingsButtonLabel: some View {
        Image(systemName: "gearshape")
            .frame(width: NimbusSyncDesignTokens.controlSize, height: NimbusSyncDesignTokens.controlSize)
    }

    private var statusOverview: some View {
        HStack(spacing: NimbusSyncDesignTokens.spacing12) {
            Image(systemName: overallStatus.symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(overallStatus.tint)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusSummary)
                    .font(.subheadline.weight(.semibold))
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: NimbusSyncDesignTokens.spacing8)
            if !domains.isEmpty {
                Text("\(domains.count)")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(overallStatus.tint)
                    .accessibilityLabel(Text("\(domains.count) connected domains"))
            }
        }
        .padding(NimbusSyncDesignTokens.spacing12)
        .background(overallStatus.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: NimbusSyncDesignTokens.cornerRadius))
        .accessibilityElement(children: .combine)
    }

    private var domainsSection: some View {
        VStack(alignment: .leading, spacing: NimbusSyncDesignTokens.spacing8) {
            sectionHeading("Domains", count: domains.count)
            ForEach(domains, id: \.identifier) { domain in
                domainRow(domain)
            }
        }
    }

    private var emptyState: some View {
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
                Label("Add domain", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NimbusSyncDesignTokens.spacing16)
    }

    private func domainRow(_ domain: DomainDescriptor) -> some View {
        HStack(alignment: .top, spacing: NimbusSyncDesignTokens.spacing8) {
            DomainIconView(iconURL: domain.iconURL, size: 30)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: NimbusSyncDesignTokens.spacing8) {
                    Text(domain.displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: NimbusSyncDesignTokens.spacing4)
                    StatusBadge(status: domain.status, compact: true)
                }
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
                if let progress = DomainCheckProgress.visible(for: domain, in: checkProgress) {
                    DomainCheckProgressView(progress: progress)
                        .padding(.top, 2)
                }
            }

            if let onCheckDomain {
                Button(action: { onCheckDomain(domain) }) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .frame(width: NimbusSyncDesignTokens.controlSize, height: NimbusSyncDesignTokens.controlSize)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!checkableDomainIdentifiers.contains(domain.identifier))
                .accessibilityLabel(Text("Check \(domain.displayName) now"))
                .help("Check Now: compare every file with the server")
            }

            Button(action: { onOpenDomain(domain) }) {
                Image(systemName: "folder")
                    .frame(width: NimbusSyncDesignTokens.controlSize, height: NimbusSyncDesignTokens.controlSize)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(Text("Open \(domain.displayName) in Finder"))
            .help("Open in Finder")
        }
        .padding(NimbusSyncDesignTokens.spacing8)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: NimbusSyncDesignTokens.cornerRadius))
    }

    static func host(of domain: DomainDescriptor) -> String {
        URL(string: domain.scope.origin)?.host ?? domain.scope.origin
    }

    private var conflictCallout: some View {
        Button(action: onOpenConflicts) {
            HStack(spacing: NimbusSyncDesignTokens.spacing8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conflicts need attention")
                        .font(.subheadline.weight(.semibold))
                    Text("Review the latest local and remote versions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: NimbusSyncDesignTokens.spacing8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(NimbusSyncDesignTokens.spacing12)
            .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: NimbusSyncDesignTokens.cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Review conflicts"))
    }

    private func taskSection(title: String, tasks: [TaskDisplay]) -> some View {
        VStack(alignment: .leading, spacing: NimbusSyncDesignTokens.spacing8) {
            sectionHeading(title, count: tasks.count)
            ForEach(tasks) { task in
                TaskProgressRow(
                    title: task.title,
                    progress: task.progress,
                    detail: task.detail,
                    state: task.state,
                    date: task.date,
                    onCancel: { onCancelTask(task.id) },
                    onRetry: { onRetryTask(task.id) }
                )
                if task.id != tasks.last?.id {
                    Divider()
                }
            }
        }
    }

    private func sectionHeading(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: NimbusSyncDesignTokens.spacing8)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("\(count) items"))
        }
    }

    private var overallStatus: DomainStatus {
        domains.map(\.status).max { lhs, rhs in lhs.priority < rhs.priority } ?? .initializing
    }

    private var summary: MenuBarStatusSummary {
        MenuBarStatusSummary(domains: domains, activeTaskCount: tasks.count, hasActionableConflicts: hasActionableConflicts)
    }

    private var statusSummary: String { summary.headline }

    private var statusDetail: String { summary.detail }
}
