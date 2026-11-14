import Foundation
import FileProvider
import CloudreveDomainKit
import CloudreveStoreBridge

/// Refreshes Finder metadata when the projection contract or UI language
/// changes. Content versions are left untouched, so a projection upgrade
/// cannot cause an otherwise unchanged file to download again.
public final class FrameworkCacheRefreshCoordinator: @unchecked Sendable {
    public static let languagePreferenceKey = "projection.localization.language"
    private let store: SQLiteStateStore
    private let manager: NSFileProviderManager?
    private let domainIdentifier: String
    private let pageSize = 200
    private let maximumPagesPerRun = 4
    private let signalOverride: (@Sendable () async throws -> Void)?

    public init(store: SQLiteStateStore, manager: NSFileProviderManager?, domainIdentifier: String, signalOverride: (@Sendable () async throws -> Void)? = nil) {
        self.store = store
        self.manager = manager
        self.domainIdentifier = domainIdentifier
        self.signalOverride = signalOverride
    }

    @discardableResult
    public func refreshIfNeeded(language: AppLanguage = L10n.language) async throws -> Bool {
        let revisions = try store.projectionRevisionState()
        let previousLanguage = try store.preference(key: Self.languagePreferenceKey)
        let pendingJob = try store.activeProjectionRefreshJob(domainIdentifier: domainIdentifier)
        guard revisions.lastApplied < max(revisions.current, ProjectionSchema.currentRevision) || previousLanguage != language.rawValue || pendingJob != nil else { return true }
        let targetRevision = max(revisions.current, ProjectionSchema.currentRevision)
        // Advance the codec revision before emitting refresh rows so anchors
        // from the previous projection cannot be mistaken for an empty delta
        // while this bounded job is in progress.
        try store.setProjectionSchemaRevision(targetRevision)
        let job = try pendingJob ?? store.beginProjectionRefresh(domainIdentifier: domainIdentifier, targetRevision: targetRevision, scope: "working_set", fallbackEnabled: false)
        var cursor = job.cursor
        do {
            for _ in 0..<maximumPagesPerRun {
                let items = try store.workingSetItems(afterIdentifier: cursor, limit: pageSize)
                if items.isEmpty {
                    try await signal()
                    // The schema revision is advanced only after the system
                    // has accepted the working-set signal. If signalling
                    // fails, the catch path keeps the job retryable and the
                    // old applied revision forces the next worker to drain
                    // the pending outbox again.
                    try store.completeProjectionRefresh(jobID: job.jobID)
                    try store.setPreference(key: Self.languagePreferenceKey, value: language.rawValue)
                    return true
                }
                let nextCursor = items.last?.itemIdentifier
                try store.commitProjectionRefreshPage(jobID: job.jobID, items: items, cursor: nextCursor)
                cursor = nextCursor
                if items.count < pageSize {
                    try await signal()
                    try store.completeProjectionRefresh(jobID: job.jobID)
                    try store.setPreference(key: Self.languagePreferenceKey, value: language.rawValue)
                    return true
                }
            }
            return false
        } catch {
            try? store.advanceProjectionRefresh(jobID: job.jobID, cursor: cursor, state: "failed", error: "projection_refresh_failed")
            throw error
        }
    }

    private func signal() async throws {
        if let signalOverride {
            try await signalOverride()
        } else if let manager {
            try await manager.signalEnumerator(for: .workingSet)
        }
        if let revision = try store.latestPendingOutboxRevision() {
            try store.acknowledgeOutbox(upTo: revision)
        }
    }
}
