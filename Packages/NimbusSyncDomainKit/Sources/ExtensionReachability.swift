import Foundation
import FileProvider

/// The XPC protocol the File Provider extension serves so the app can tell whether macOS can
/// actually start it. A Domain can look healthy in the registry while every Finder request fails
/// because the extension dies at launch (an invalid signature, or launchd still bootstrapping a
/// stale copy of the same bundle ID from another path); only a round trip to the extension
/// itself shows that.
@objc public protocol NimbusSyncExtensionProbing {
    /// Replies with the extension's bundle path and full version.
    func probe(reply: @escaping @Sendable (String, String) -> Void)
}

public enum ExtensionProbeService {
    /// Served on the root container of every Domain.
    public static var name: NSFileProviderServiceName {
        NSFileProviderServiceName("\(AppIdentity.baseIdentifier).extension-probe")
    }

    public static func makeInterface() -> NSXPCInterface {
        NSXPCInterface(with: NimbusSyncExtensionProbing.self)
    }
}

/// What one probe of a Domain's extension found.
public enum ExtensionProbeResult: Equatable, Sendable {
    /// The extension answered from `bundlePath`.
    case answered(bundlePath: String, version: String)
    /// The user switched the Domain off in System Settings; macOS will not start the extension,
    /// and the Finder integration state already reports that.
    case domainDisabled
    /// The extension answered no probe service: an old build is serving the Domain.
    case serviceMissing
    case timedOut
    case failed(stage: String, domain: String, code: Int)

    public var diagnosticDescription: String {
        switch self {
        case .answered: "answered"
        case .domainDisabled: "domain_disabled"
        case .serviceMissing: "service_missing"
        case .timedOut: "timed_out"
        case let .failed(stage, domain, code): "\(stage):\(domain):\(code)"
        }
    }

    static func classify(_ error: Error, stage: String) -> ExtensionProbeResult {
        let nsError = error as NSError
        if (nsError.domain == NSFileProviderErrorDomain && nsError.code == -2011) ||
            (nsError.domain == "NSFileProviderInternalErrorDomain" && nsError.code == 12) {
            return .domainDisabled
        }
        return .failed(stage: stage, domain: nsError.domain, code: nsError.code)
    }
}

/// Why the extension counts as unavailable.
public enum ExtensionUnavailableReason: String, Equatable, Sendable {
    /// It could not be started or did not answer.
    case notResponding = "not_responding"
    /// It answered from another copy of NimbusSync than the running app's.
    case staleCopy = "stale_copy"
}

/// Turns probe results into a per-Domain verdict. One failed probe can be a slow first launch,
/// so `notResponding` waits for a second; an answer from the wrong copy is conclusive at once.
public struct ExtensionReachabilityTracker: Equatable, Sendable {
    public static let failureThreshold = 2
    /// How long to wait before the next probe: soon while something is wrong, rarely otherwise.
    public static let healthyInterval: TimeInterval = 300
    public static let failingInterval: TimeInterval = 30

    public private(set) var consecutiveFailures = 0
    public private(set) var reason: ExtensionUnavailableReason?

    public init() {}

    public var unavailableReason: ExtensionUnavailableReason? {
        guard let reason else { return nil }
        return reason == .staleCopy || consecutiveFailures >= Self.failureThreshold ? reason : nil
    }

    public var nextProbeInterval: TimeInterval {
        consecutiveFailures > 0 ? Self.failingInterval : Self.healthyInterval
    }

    /// `expectedBundlePath` is the extension embedded in the running app; nil skips the check.
    public mutating func record(_ result: ExtensionProbeResult, expectedBundlePath: String?) {
        switch result {
        case let .answered(bundlePath, _):
            if let expectedBundlePath, !Self.samePath(bundlePath, expectedBundlePath) {
                consecutiveFailures += 1
                reason = .staleCopy
            } else {
                consecutiveFailures = 0
                reason = nil
            }
        case .domainDisabled:
            // Not the extension's fault, and not knowable while it is off.
            consecutiveFailures = 0
            reason = nil
        case .serviceMissing, .timedOut, .failed:
            consecutiveFailures += 1
            reason = .notResponding
        }
    }

    static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        // realpath resolves /tmp to /private/tmp; Foundation's symlink resolution strips /private
        // instead, and only for paths that exist.
        func normalized(_ path: String) -> String {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard let resolved = realpath(standardized, nil) else { return standardized }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return normalized(lhs) == normalized(rhs)
    }
}

public enum ExtensionReachability {
    /// The Domains as the UI shows them: a Domain whose extension is unavailable reads
    /// `extensionUnavailable`. Removal and repair states keep their own status, because only
    /// they offer the action that finishes them. Never persist the result.
    public static func overlay(_ domains: [DomainDescriptor], unavailable: Set<String>) -> [DomainDescriptor] {
        guard !unavailable.isEmpty else { return domains }
        return domains.map { domain in
            guard unavailable.contains(domain.identifier), !domain.status.isLifecycleHold else { return domain }
            var shown = domain
            shown.status = .extensionUnavailable
            return shown
        }
    }

    /// Asks the Domain's extension to answer over its probe service. Never throws: every way
    /// the round trip can end is a result.
    public static func probe(domainIdentifier: String, timeout: TimeInterval = 20) async -> ExtensionProbeResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<ExtensionProbeResult, Never>) in
            let gate = ProbeGate(continuation)
            let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(domainIdentifier), displayName: domainIdentifier)
            guard let manager = NSFileProviderManager(for: domain) else {
                gate.finish(.failed(stage: "manager", domain: "NimbusSync", code: 0))
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                gate.finish(.timedOut)
            }
            manager.getService(named: ExtensionProbeService.name, for: .rootContainer) { service, error in
                if let error {
                    gate.finish(ExtensionProbeResult.classify(error, stage: "service"))
                    return
                }
                guard let service else {
                    gate.finish(.serviceMissing)
                    return
                }
                service.getFileProviderConnection { connection, error in
                    if let error {
                        gate.finish(ExtensionProbeResult.classify(error, stage: "connection"))
                        return
                    }
                    guard let connection else {
                        gate.finish(.serviceMissing)
                        return
                    }
                    connection.remoteObjectInterface = ExtensionProbeService.makeInterface()
                    gate.hold(connection)
                    connection.resume()
                    let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                        gate.finish(ExtensionProbeResult.classify(error, stage: "probe"))
                    } as? NimbusSyncExtensionProbing
                    guard let proxy else {
                        gate.finish(.serviceMissing)
                        return
                    }
                    proxy.probe { bundlePath, version in
                        gate.finish(.answered(bundlePath: bundlePath, version: version))
                    }
                }
            }
        }
    }
}

/// Resumes the probe exactly once and closes its connection.
private final class ProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ExtensionProbeResult, Never>?
    private var connection: NSXPCConnection?

    init(_ continuation: CheckedContinuation<ExtensionProbeResult, Never>) {
        self.continuation = continuation
    }

    func hold(_ connection: NSXPCConnection) {
        lock.lock()
        let finished = continuation == nil
        if !finished { self.connection = connection }
        lock.unlock()
        if finished { connection.invalidate() }
    }

    func finish(_ result: ExtensionProbeResult) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let connection = self.connection
        self.connection = nil
        lock.unlock()
        connection?.invalidate()
        continuation?.resume(returning: result)
    }
}
