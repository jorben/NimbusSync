import Foundation

/// How far a Domain's full check against the server has come.
///
/// The server never reports the size of the whole tree up front, so the total is an estimate: the
/// number of items the previous check left in the local store. Repeat checks, the common case, land
/// close to it; a first check has nothing to compare against and reports a count only.
public struct DomainCheckProgress: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case scanningFiles = "scanning_normal"
        case scanningTrash = "scanning_trash"
        case applyingDeletions = "applying_deletions"
    }

    public let phase: Phase
    public let scannedItems: Int
    /// Items known before this check began; 0 when there is no estimate.
    public let expectedItems: Int
    public let startedAt: Date
    /// The check's last sign of life; a running check reports at least once per server request.
    public let updatedAt: Date

    public init(phase: Phase, scannedItems: Int, expectedItems: Int, startedAt: Date, updatedAt: Date? = nil) {
        self.phase = phase
        self.scannedItems = max(0, scannedItems)
        self.expectedItems = max(0, expectedItems)
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
    }

    /// A check silent this long is no longer running (its process was killed or suspended).
    /// Requests time out after 30 seconds, so a live check reports far more often.
    public static let staleAfter: TimeInterval = 5 * 60

    public func isStale(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) >= Self.staleAfter
    }

    /// The estimated share done, or nil when there is no estimate. It never claims completion:
    /// the check is done when the status changes, not when a guess reaches 100%.
    public var estimatedFraction: Double? {
        guard expectedItems > 0 else { return nil }
        if phase == .applyingDeletions { return Self.ceiling }
        let fraction = Double(scannedItems) / Double(max(expectedItems, scannedItems))
        return min(Self.ceiling, max(0, fraction))
    }

    static let ceiling = 0.99

    /// Short checks finish before a bar could mean anything; showing one would only flicker.
    public func isWorthShowing(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(startedAt) >= Self.minimumVisibleAge && !isStale(at: now)
    }

    static let minimumVisibleAge: TimeInterval = 2
}
