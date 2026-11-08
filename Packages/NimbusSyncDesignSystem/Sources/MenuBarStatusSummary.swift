import Foundation
import CloudreveDomainKit

/// What NimbusSync is doing right now, in words. The popover's status card and the menu bar
/// item's hover tooltip read the same summary, so they can never disagree.
public struct MenuBarStatusSummary: Sendable, Equatable {
    public let headline: String
    public let detail: String
    /// One short line under the app name in the popover header, for example "Syncing 1 of 2 domains".
    public let subtitle: String
    /// Multi-line text for the status item's tooltip: the headline, then one line per domain,
    /// transfers and conflicts.
    public let tooltip: String

    static let maximumDomainLines = 5

    public init(domains: [DomainDescriptor], activeTaskCount: Int, hasActionableConflicts: Bool) {
        let attentionCount = domains.filter { $0.status.needsAttention }.count
        let overall = domains.map(\.status).max { $0.priority < $1.priority } ?? .initializing

        if domains.isEmpty {
            headline = "Ready to connect"
            detail = "Connect a Cloudreve domain to get started."
        } else if attentionCount > 0 {
            headline = "Needs your attention"
            detail = "\(attentionCount) domain\(attentionCount == 1 ? "" : "s") need a review."
        } else if activeTaskCount > 0 {
            headline = "Syncing your files"
            detail = "Changes are being processed in the background."
        } else {
            headline = overall.title
            detail = switch overall {
            case .healthy: "Your connected domains are ready in Finder."
            case .eventDegraded: "Live updates are unavailable; NimbusSync will reconcile when possible."
            case .appNotRunning: "NimbusSync is not running; launch it to resume live updates."
            case .syncing: "NimbusSync is processing changes in the background."
            case .reconciling, .initializing: "NimbusSync is checking your connected domains."
            case .removalPreflight: "A domain is being removed."
            default: "Your connected domains are being prepared."
            }
        }

        subtitle = Self.subtitle(domains: domains, attentionCount: attentionCount, activeTaskCount: activeTaskCount, overall: overall)

        var lines = ["NimbusSync — \(headline)"]
        if domains.isEmpty {
            lines.append(detail)
        } else {
            for domain in domains.prefix(Self.maximumDomainLines) {
                lines.append("\(domain.displayName): \(domain.status.title)")
            }
            if domains.count > Self.maximumDomainLines {
                lines.append("and \(domains.count - Self.maximumDomainLines) more")
            }
        }
        if activeTaskCount > 0 {
            lines.append("\(activeTaskCount) transfer\(activeTaskCount == 1 ? "" : "s") in progress")
        }
        if hasActionableConflicts {
            lines.append("Conflicts need review")
        }
        tooltip = lines.joined(separator: "\n")
    }

    private static func subtitle(domains: [DomainDescriptor], attentionCount: Int, activeTaskCount: Int, overall: DomainStatus) -> String {
        let total = domains.count
        let busy = domains.filter { $0.status == .syncing || $0.status == .reconciling }.count
        if total == 0 { return "No domains connected" }
        if attentionCount > 0 {
            return total == 1 ? "Needs your attention" : "\(attentionCount) of \(total) domains need attention"
        }
        if busy > 0 {
            return total == 1 ? "Syncing" : "Syncing \(busy) of \(total) domains"
        }
        if activeTaskCount > 0 {
            return "Syncing \(activeTaskCount) file\(activeTaskCount == 1 ? "" : "s")"
        }
        if domains.allSatisfy({ $0.status == .healthy }) {
            return total == 1 ? "Up to date" : "All \(total) domains up to date"
        }
        return overall.title
    }
}

extension DomainStatus {
    var needsAttention: Bool {
        switch self {
        case .healthy, .syncing, .reconciling, .initializing, .eventDegraded, .appNotRunning, .removalPreflight:
            return false
        case .offline, .authExpired, .rootUnavailable, .scopeConflict, .conflict, .permanentError, .repairRequired, .preservedRemoval:
            return true
        }
    }
}
