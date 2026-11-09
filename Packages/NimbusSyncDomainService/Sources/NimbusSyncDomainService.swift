import Foundation
import FileProvider
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveAuthKit

public enum DomainProvisioningError: Error, Equatable, LocalizedError, Sendable {
    case overlappingScope
    case accountMismatch
    case rootUnavailable
    case invalidDisplayName
    case displayNameUnavailable
    case displayNameInUse
    case renameUnavailable
    case system(String)
    case rollbackRequired(String)

    public var errorDescription: String? {
        switch self {
        case .overlappingScope:
            "This Cloudreve location overlaps an existing NimbusSync location."
        case .accountMismatch:
            "The authorized Cloudreve account does not match the selected location."
        case .rootUnavailable:
            "The selected Cloudreve root is no longer available."
        case .invalidDisplayName:
            "Choose a non-empty domain name without control characters."
        case .displayNameUnavailable:
            "A Finder location with this name already exists. Choose a different name, or remove the old NimbusSync location in System Settings."
        case .displayNameInUse:
            "Another domain already uses this name. Choose a different name."
        case .renameUnavailable:
            "This domain can't be renamed while it is being removed or repaired."
        case .system:
            "NimbusSync could not complete the File Provider operation."
        case .rollbackRequired:
            "NimbusSync could not add this Cloudreve location to Finder. Check that NimbusSync is enabled under System Settings > General > Login Items & Extensions > File Providers, then try again."
        }
    }

    public var diagnosticDescription: String {
        switch self {
        case .overlappingScope:
            "overlapping_scope"
        case .accountMismatch:
            "account_mismatch"
        case .rootUnavailable:
            "root_unavailable"
        case .invalidDisplayName:
            "invalid_display_name"
        case .displayNameUnavailable:
            "display_name_unavailable"
        case .displayNameInUse:
            "display_name_in_use"
        case .renameUnavailable:
            "rename_unavailable"
        case let .system(detail), let .rollbackRequired(detail):
            detail
        }
    }
}

public struct VerifiedDomainIdentity: Equatable, Sendable {
    public let accountID: String
    public let rootRemoteID: String
    public let rootURI: String
    public init(accountID: String, rootRemoteID: String, rootURI: String) { self.accountID = accountID; self.rootRemoteID = rootRemoteID; self.rootURI = rootURI }
}

/// Resolves the untrusted OAuth callback hints through the authenticated
/// Cloudreve API before a Domain is persisted.
public final class CloudreveIdentityResolver: @unchecked Sendable {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: configuration, delegate: SameOriginRedirectPolicy(), delegateQueue: nil)
        }
    }

    public func resolve(origin: URL, credential: Credential, rootURI: String) async throws -> VerifiedDomainIdentity {
        let user: UserResponse = try await request(origin: origin, credential: credential, path: "user/me", query: [])
        let root: RemoteRootResponse = try await request(origin: origin, credential: credential, path: "file/info", query: [URLQueryItem(name: "uri", value: rootURI), URLQueryItem(name: "extended", value: "true")])
        guard !user.id.isEmpty, !root.id.isEmpty, root.type == 1 else { throw DomainProvisioningError.rootUnavailable }
        let scope = try RemoteScope(origin: origin.absoluteString, accountID: user.id, rootURI: root.path)
        return VerifiedDomainIdentity(accountID: user.id, rootRemoteID: root.id, rootURI: scope.rootURI)
    }

    public func accountID(origin: URL, credential: Credential) async throws -> String {
        let user: UserResponse = try await request(origin: origin, credential: credential, path: "user/me", query: [])
        guard !user.id.isEmpty else { throw DomainProvisioningError.accountMismatch }
        return user.id
    }

    public func verifyFirstRead(origin: URL, credential: Credential, rootURI: String) async throws {
        let _: RemoteListResponse = try await request(origin: origin, credential: credential, path: "file", query: [URLQueryItem(name: "uri", value: rootURI), URLQueryItem(name: "page_size", value: "1")])
    }

    private func request<Value: Decodable>(origin: URL, credential: Credential, path: String, query: [URLQueryItem]) async throws -> Value {
        var components = URLComponents(url: origin.appendingPathComponent("api/v4").appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.setCloudreveQueryItems(query)
        guard let url = components?.url else { throw CoreFailure(code: .network, retryable: true) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CoreFailure(code: .network, retryable: true) }
        if http.statusCode == 401 { throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true) }
        guard (200..<300).contains(http.statusCode) else { throw CoreFailure(code: .network, retryable: true) }
        let envelope = try JSONDecoder().decode(APIEnvelope<Value>.self, from: data)
        guard envelope.code == 0, let value = envelope.data else { throw CoreFailure(code: .unknownOutcome, retryable: false) }
        return value
    }
}

private struct APIEnvelope<Value: Decodable>: Decodable { let code: Int; let msg: String?; let data: Value? }
private struct UserResponse: Decodable { let id: String }
private struct RemoteRootResponse: Decodable { let type: Int; let id: String; let path: String }
private struct RemoteListResponse: Decodable { let files: [RemoteRootResponse] }

private final class SameOriginRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var request = request
        let current = task.currentRequest?.url
        let next = request.url
        if current?.scheme != next?.scheme || current?.host != next?.host || current?.port != next?.port { request.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(request)
    }
}

public actor DomainRegistryService {
    private let store: SQLiteStateStore
    private let vault: CredentialVault
    private let lifecycle: DomainLifecycleService
    private let scopeGuard: ScopeGuard
    private let storeFactory: AppGroupStoreFactory?

    public init(store: SQLiteStateStore, vault: CredentialVault, lifecycle: DomainLifecycleService = DomainLifecycleService(), scopeGuard: ScopeGuard = ScopeGuard(), storeFactory: AppGroupStoreFactory? = nil) {
        self.store = store; self.vault = vault; self.lifecycle = lifecycle; self.scopeGuard = scopeGuard; self.storeFactory = storeFactory
    }

    public func provision(displayName: String, scope: RemoteScope, credential: Credential, capabilitySnapshot: CapabilitySnapshot, iconURL: URL? = nil, resolveIdentity: @Sendable () async throws -> VerifiedDomainIdentity, firstRead: @Sendable () async throws -> Void) async throws -> DomainDescriptor {
        let normalizedDisplayName = try DomainDisplayName.normalized(displayName)
        let identity = try await resolveIdentity()
        guard identity.accountID == scope.accountID else { throw DomainProvisioningError.accountMismatch }
        guard !identity.rootRemoteID.isEmpty else { throw DomainProvisioningError.rootUnavailable }
        let verifiedScope = try RemoteScope(origin: scope.origin, accountID: identity.accountID, rootURI: identity.rootURI)
        let existing = try store.allDomains().compactMap { stored -> DomainDescriptor? in
            guard let oldScope = try? RemoteScope(origin: stored.origin, accountID: stored.accountID, rootURI: stored.rootURI) else { return nil }
            return DomainDescriptor(identifier: stored.identifier, displayName: stored.displayName, scope: oldScope, rootRemoteID: stored.rootRemoteID, accountID: stored.accountID, secretReference: stored.secretReference, capabilitySnapshot: stored.capabilitySnapshot, iconURL: stored.iconURL)
        }
        try scopeGuard.validate(newScope: verifiedScope, existing: existing)
        guard !existing.contains(where: { $0.displayName.caseInsensitiveCompare(normalizedDisplayName) == .orderedSame }) else {
            throw DomainProvisioningError.invalidDisplayName
        }
        // Replicated File Provider roots are system-owned. A previous domain
        // with the same visible name can make addDomain fail with file-exists
        // even when the app registry has already been cleared.
        let registeredDomains = try await lifecycle.registeredDomains()
        if registeredDomains.contains(where: { $0.displayName.caseInsensitiveCompare(normalizedDisplayName) == .orderedSame }) {
            throw DomainProvisioningError.displayNameUnavailable
        }
        let descriptor = DomainDescriptor(displayName: normalizedDisplayName, scope: verifiedScope, rootRemoteID: identity.rootRemoteID, accountID: identity.accountID, secretReference: "credential-\(UUID().uuidString)", capabilitySnapshot: capabilitySnapshot, iconURL: iconURL)
        try store.beginProvisioning(domainID: descriptor.identifier, secretReference: descriptor.secretReference)
        var systemDomainAdded = false
        var systemDomainRegistrationStarted = false
        do {
            try vault.write(credential, reference: descriptor.secretReference)
            try store.advanceProvisioning(domainID: descriptor.identifier, step: .credentialWritten)
            let domainStore = try storeFactory?.domainStore(identifier: descriptor.identifier)
            try domainStore?.registerDomain(descriptor)
            try store.registerDomain(descriptor)
            try store.advanceProvisioning(domainID: descriptor.identifier, step: .domainDatabaseReady)
            let systemDomain = try lifecycle.makeSystemDomain(for: descriptor, trashEnabled: descriptor.capabilitySnapshot.canTrash)
            systemDomainRegistrationStarted = true
            try await lifecycle.add(systemDomain)
            systemDomainAdded = true
            try store.advanceProvisioning(domainID: descriptor.identifier, step: .systemDomainAdded)
            try await firstRead()
            try store.setDomainStatus(identifier: descriptor.identifier, status: .healthy)
            try store.advanceProvisioning(domainID: descriptor.identifier, step: .firstReadHealthy)
            try store.finishProvisioning(domainID: descriptor.identifier)
            return descriptor
        } catch {
            var systemDomainPresent = systemDomainAdded
            var systemDomainOutcomeUncertain = false
            if systemDomainRegistrationStarted && !systemDomainPresent {
                do {
                    systemDomainPresent = try await lifecycle.systemDomainExists(descriptor.identifier)
                } catch {
                    // Keep the saga durable when the add callback and the
                    // follow-up lookup both have an uncertain outcome.
                    systemDomainOutcomeUncertain = true
                }
            }
            let diagnostic = provisioningDiagnostic(for: error)
            try? store.advanceProvisioning(domainID: descriptor.identifier, step: .rollbackRequired, error: diagnostic)
            if !systemDomainPresent && !systemDomainOutcomeUncertain {
                try? vault.remove(reference: descriptor.secretReference)
                try? store.removeDomainRecord(identifier: descriptor.identifier)
                try? storeFactory?.removeDomainStore(identifier: descriptor.identifier)
            } else {
                try? store.setDomainStatus(identifier: descriptor.identifier, status: .repairRequired)
            }
            throw DomainProvisioningError.rollbackRequired(diagnostic)
        }
    }

    public func recoverProvisioning() async {
        guard let records = try? store.incompleteProvisioning() else { return }
        guard let domains = try? await lifecycle.registeredDomains() else { return }
        let systemIDs = Set(domains.map(\.identifier))
        for record in records {
            let next = DomainProvisioningReducer.recover(record: record, systemDomainExists: systemIDs.contains(record.domainID))
            if next == .rollbackRequired {
                let stored: StoredDomain?
                do { stored = try store.domain(identifier: record.domainID) } catch { stored = nil }
                if let stored {
                    if systemIDs.contains(record.domainID) {
                        try? store.setDomainStatus(identifier: record.domainID, status: .repairRequired)
                    } else {
                        try? vault.remove(reference: stored.secretReference)
                        try? store.removeDomainRecord(identifier: record.domainID)
                        try? storeFactory?.removeDomainStore(identifier: record.domainID)
                        try? store.finishProvisioningRollback(domainID: record.domainID)
                    }
                } else {
                    if let secretReference = record.secretReference { try? vault.remove(reference: secretReference) }
                    try? storeFactory?.removeDomainStore(identifier: record.domainID)
                    try? store.finishProvisioningRollback(domainID: record.domainID)
                }
            } else if next == .registered {
                try? store.finishProvisioning(domainID: record.domainID)
                try? store.setDomainStatus(identifier: record.domainID, status: .healthy)
            } else {
                try? store.advanceProvisioning(domainID: record.domainID, step: next)
                if next != .registered { try? store.setDomainStatus(identifier: record.domainID, status: .repairRequired) }
            }
        }
    }

    /// Fail-closed startup reconciliation: system File Provider domains with
    /// no backing record in the app registry are removed so they stop
    /// surfacing permanently broken Finder locations. Both the registry read
    /// and the system listing must succeed before anything is removed, and
    /// removal always preserves dirty user data (on macOS 14 and later; on
    /// older systems it fails closed and leaves the domain registered).
    @discardableResult
    public func removeOrphanedSystemDomains() async -> OrphanedDomainCleanupReport {
        let storedDomains: [StoredDomain]
        do { storedDomains = try store.allDomains() } catch { return OrphanedDomainCleanupReport(outcome: .registryUnreadable) }
        let registryIdentifiers = storedDomains.map(\.identifier)
        let systemDomains: [RegisteredDomainSnapshot]
        do { systemDomains = try await lifecycle.registeredDomains() } catch {
            return OrphanedDomainCleanupReport(outcome: .systemListingFailed, registryIdentifiers: registryIdentifiers, error: Self.errorCode(error))
        }
        // An empty registry next to registered system domains is far more
        // likely a recreated/reset App Group database than a user who removed
        // every location; removing them all would make every sync location
        // disappear from Finder. Only prune when the registry has content.
        // The system list above is read only so the report can show them.
        guard !storedDomains.isEmpty else {
            return OrphanedDomainCleanupReport(outcome: .registryEmpty, registryIdentifiers: registryIdentifiers, systemIdentifiers: systemDomains.map(\.identifier))
        }
        let orphanedIdentifiers = OrphanedDomainCleanupReducer.orphanedIdentifiers(systemDomains: systemDomains, registryIdentifiers: Set(registryIdentifiers))
        var report = OrphanedDomainCleanupReport(outcome: .checked, registryIdentifiers: registryIdentifiers, systemIdentifiers: systemDomains.map(\.identifier))
        for snapshot in systemDomains where orphanedIdentifiers.contains(snapshot.identifier) {
            let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(snapshot.identifier), displayName: snapshot.displayName)
            do {
                let preservedLocation = try await lifecycle.remove(domain, preserveDirtyData: true)
                report.removed.append((snapshot.identifier, preservedLocation))
            } catch {
                // Fail-closed: leave this domain registered and continue with the rest, but say
                // why, or an orphan nobody manages keeps serving stale items without a trace.
                report.failed.append((snapshot.identifier, Self.errorCode(error)))
            }
        }
        return report
    }

    /// A redacted error code for diagnostics: the type, domain and code only, never a message.
    static func errorCode(_ error: Error) -> String {
        if let lifecycleError = error as? DomainLifecycleError { return lifecycleError.diagnosticDescription }
        let nsError = error as NSError
        return "\(nsError.domain):\(nsError.code)"
    }

    /// Registry rows that cannot be turned into a Domain, with which part is unreadable. They are
    /// invisible everywhere else: not listed in Settings, never synced, yet never orphans either.
    public func unreadableDomains() -> [(identifier: String, status: String, reason: String)] {
        guard let stored = try? store.allDomains() else { return [] }
        return stored.compactMap { domain in
            guard let reason = RemoteScope.invalidityReason(origin: domain.origin, accountID: domain.accountID, rootURI: domain.rootURI) else { return nil }
            return (domain.identifier, domain.status.rawValue, reason)
        }
    }

    public func descriptors() throws -> [DomainDescriptor] {
        try store.allDomains().compactMap { stored in
            guard let scope = try? RemoteScope(origin: stored.origin, accountID: stored.accountID, rootURI: stored.rootURI) else { return nil }
            var descriptor = DomainDescriptor(identifier: stored.identifier, displayName: stored.displayName, scope: scope, rootRemoteID: stored.rootRemoteID, accountID: stored.accountID, secretReference: stored.secretReference, capabilitySnapshot: stored.capabilitySnapshot, iconURL: stored.iconURL)
            descriptor.status = stored.status
            return descriptor
        }
    }

    private func provisioningDiagnostic(for error: Error) -> String {
        if let lifecycleError = error as? DomainLifecycleError {
            return lifecycleError.diagnosticDescription
        }
        if let provisioningError = error as? DomainProvisioningError {
            return provisioningError.diagnosticDescription
        }
        if let coreFailure = error as? CoreFailure {
            return "core_failure:\(coreFailure.code.rawValue)"
        }
        let nsError = error as NSError
        return "error:\(nsError.domain):\(nsError.code)"
    }
}

/// The rules a Domain's user-visible name follows, shared by adding and renaming.
public enum DomainDisplayName {
    /// The trimmed name, or `invalidDisplayName` when it is empty, too long or has control characters.
    public static func normalized(_ rawValue: String) throws -> String {
        let name = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.count <= DomainDescriptor.maxDisplayNameLength,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DomainProvisioningError.invalidDisplayName
        }
        return name
    }
}

/// Renames a Domain locally: the registry and Domain database rows and, when macOS has it
/// registered, the Finder location's display name. The Domain identifier, remote scope,
/// credential reference, status and sync state are never touched, so syncing carries on.
public actor DomainRenameService {
    private let store: SQLiteStateStore
    private let domainStore: (@Sendable (String) throws -> SQLiteStateStore)?
    private let registeredDomains: @Sendable () async throws -> [RegisteredDomainSnapshot]
    private let updateSystemDomain: @Sendable (DomainDescriptor) async throws -> Void

    public init(
        store: SQLiteStateStore,
        domainStore: (@Sendable (String) throws -> SQLiteStateStore)? = nil,
        lifecycle: DomainLifecycleService = DomainLifecycleService(),
        registeredDomains: (@Sendable () async throws -> [RegisteredDomainSnapshot])? = nil,
        updateSystemDomain: (@Sendable (DomainDescriptor) async throws -> Void)? = nil
    ) {
        self.store = store
        self.domainStore = domainStore
        self.registeredDomains = registeredDomains ?? { try await lifecycle.registeredDomains() }
        // addDomain with an identifier macOS already knows only updates its display name
        // (and hidden state); the replicated root and its contents stay where they are.
        self.updateSystemDomain = updateSystemDomain ?? { descriptor in
            let domain = try lifecycle.makeSystemDomain(for: descriptor, trashEnabled: descriptor.capabilitySnapshot.canTrash)
            try await lifecycle.add(domain)
        }
    }

    /// Returns the name that was stored (trimmed).
    @discardableResult
    public func rename(descriptor: DomainDescriptor, to rawName: String) async throws -> String {
        let name = try DomainDisplayName.normalized(rawName)
        guard let stored = try store.domain(identifier: descriptor.identifier) else { throw StoreBridgeError.unknownDomain }
        guard !stored.status.isLifecycleHold else { throw DomainProvisioningError.renameUnavailable }
        guard stored.displayName != name else { return name }
        let others = try store.allDomains().filter { $0.identifier != descriptor.identifier }
        guard !others.contains(where: { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw DomainProvisioningError.displayNameInUse
        }
        // A leftover system location with the same name (one the registry no longer knows)
        // would show two identical entries in Finder's sidebar.
        let system = try await registeredDomains()
        if system.contains(where: { $0.identifier != descriptor.identifier && $0.displayName.caseInsensitiveCompare(name) == .orderedSame }) {
            throw DomainProvisioningError.displayNameUnavailable
        }
        // Only refresh a location macOS already has: adding an unknown identifier would
        // create a new Finder location rather than rename one.
        let systemRegistered = system.contains { $0.identifier == descriptor.identifier }
        var renamed = descriptor
        renamed.displayName = name
        if systemRegistered { try await updateSystemDomain(renamed) }
        do {
            if let domainStore { try domainStore(descriptor.identifier).updateDomainDisplayName(identifier: descriptor.identifier, displayName: name) }
            guard try store.updateDomainDisplayName(identifier: descriptor.identifier, displayName: name) else { throw StoreBridgeError.unknownDomain }
        } catch {
            if let domainStore { _ = try? domainStore(descriptor.identifier).updateDomainDisplayName(identifier: descriptor.identifier, displayName: stored.displayName) }
            if systemRegistered {
                var previous = descriptor
                previous.displayName = stored.displayName
                try? await updateSystemDomain(previous)
            }
            throw error
        }
        return name
    }
}

public actor SafeDomainRemovalService {
    private let store: SQLiteStateStore
    private let vault: CredentialVault
    private let lifecycle: DomainLifecycleService
    private let storeFactory: AppGroupStoreFactory?
    private let systemDomainExists: @Sendable (String) async throws -> Bool

    public init(
        store: SQLiteStateStore,
        vault: CredentialVault,
        lifecycle: DomainLifecycleService = DomainLifecycleService(),
        storeFactory: AppGroupStoreFactory? = nil,
        systemDomainExists: (@Sendable (String) async throws -> Bool)? = nil
    ) {
        self.store = store
        self.vault = vault
        self.lifecycle = lifecycle
        self.storeFactory = storeFactory
        self.systemDomainExists = systemDomainExists ?? { identifier in
            try await lifecycle.systemDomainExists(identifier)
        }
    }

    public func remove(descriptor: DomainDescriptor) async throws -> URL? {
        let domain = try lifecycle.makeSystemDomain(for: descriptor, trashEnabled: descriptor.capabilitySnapshot.canTrash)
        let domainStore = try storeFactory?.domainStore(identifier: descriptor.identifier) ?? store
        guard try await systemDomainExists(descriptor.identifier) else {
            throw DomainProvisioningError.system("File Provider domain is not registered")
        }
        try setRemovalStatus(.removalPreflight, domainStore: domainStore, identifier: descriptor.identifier)
        // A failed or timed-out wait means the local state is uncertain. The
        // removal policy handles that case by preserving dirty user data.
        let waitSucceeded = (try? await lifecycle.waitForChanges(below: domain)) ?? false
        let pending = try domainStore.pendingSetState()
        let decision = DomainRemovalPolicy().decision(hasDirtyOperations: try domainStore.hasDirtyWork(), pendingSetReliable: !pending.capped, waitForChangesSucceeded: waitSucceeded)
        guard decision == .safe || decision == .preserveDirtyData else { throw DomainProvisioningError.rollbackRequired("domain removal preflight blocked") }
        let preserve = decision == .preserveDirtyData
        do {
            let preserved: URL?
            if #available(macOS 14.0, *) {
                preserved = try await lifecycle.remove(domain, preserveDirtyData: preserve)
            } else if preserve {
                throw DomainProvisioningError.rollbackRequired("preserve dirty data requires macOS 14 or newer")
            } else {
                preserved = try await lifecycle.remove(domain, preserveDirtyData: false)
            }

            if preserve {
                // The system has removed the Finder registration, but the
                // returned location is now the only user-visible recovery
                // boundary for dirty local data. Keep both stores and the
                // Keychain reference until the user explicitly confirms that
                // the preserved copy is handled; deleting the metadata here
                // would make the recovery state impossible to audit.
                guard let preserved, FileManager.default.fileExists(atPath: preserved.path) else {
                    try? setRemovalStatus(.repairRequired, domainStore: domainStore, identifier: descriptor.identifier)
                    throw DomainProvisioningError.rollbackRequired("File Provider did not return a readable preserved-data location")
                }
                try setRemovalStatus(.preservedRemoval, domainStore: domainStore, identifier: descriptor.identifier)
                return preserved
            }

            // Only the clean, fully acknowledged path is allowed to remove
            // durable credentials and metadata after File Provider confirms
            // the Domain removal.
            try removeDurableRecords(descriptor: descriptor, domainStore: domainStore)
            return nil
        } catch {
            // A system callback can fail or time out after the operation has
            // become externally visible. Preserve the records and make the
            // repair requirement explicit; never turn uncertainty into a
            // destructive cleanup.
            try? setRemovalStatus(.repairRequired, domainStore: domainStore, identifier: descriptor.identifier)
            throw error
        }
    }

    /// Completes a user-confirmed removal after File Provider has already
    /// preserved dirty data and removed the system Domain. This is deliberately
    /// separate from `remove`: callers must present the preserved-data boundary
    /// and obtain explicit confirmation before deleting credentials and stores.
    public func finalizePreservedRemoval(descriptor: DomainDescriptor) async throws {
        guard descriptor.status == .preservedRemoval else {
            throw DomainProvisioningError.rollbackRequired("preserved removal has not been confirmed")
        }
        guard try await systemDomainExists(descriptor.identifier) == false else {
            throw DomainProvisioningError.rollbackRequired("File Provider domain is still registered")
        }
        let domainStore = try storeFactory?.domainStore(identifier: descriptor.identifier) ?? store
        try removeDurableRecords(descriptor: descriptor, domainStore: domainStore)
    }

    private func removeDurableRecords(descriptor: DomainDescriptor, domainStore: SQLiteStateStore) throws {
        try vault.remove(reference: descriptor.secretReference)
        try store.removeDomainRecord(identifier: descriptor.identifier)
        if storeFactory != nil {
            try domainStore.removeDomainRecord(identifier: descriptor.identifier)
            try storeFactory?.removeDomainStore(identifier: descriptor.identifier)
        }
    }

    private func setRemovalStatus(_ status: DomainStatus, domainStore: SQLiteStateStore, identifier: String) throws {
        try domainStore.setDomainStatus(identifier: identifier, status: status)
        if store !== domainStore {
            try store.setDomainStatus(identifier: identifier, status: status)
        }
    }
}

/// What the startup cleanup of system Domains without a registry record found and did.
public struct OrphanedDomainCleanupReport: Sendable {
    public enum Outcome: String, Sendable {
        case checked
        /// The registry could not be read; nothing was compared.
        case registryUnreadable = "registry_unreadable"
        /// The registry is empty, which looks like a reset database; nothing is removed.
        case registryEmpty = "registry_empty"
        case systemListingFailed = "system_listing_failed"
    }

    public var outcome: Outcome
    /// nil when the list was never collected, so it is not mistaken for an empty one.
    public var registryIdentifiers: [String]?
    public var systemIdentifiers: [String]?
    public var removed: [(identifier: String, preservedLocation: URL?)] = []
    public var failed: [(identifier: String, error: String)] = []
    public var error: String?

    public init(outcome: Outcome, registryIdentifiers: [String]? = nil, systemIdentifiers: [String]? = nil, error: String? = nil) {
        self.outcome = outcome
        self.registryIdentifiers = registryIdentifiers
        self.systemIdentifiers = systemIdentifiers
        self.error = error
    }

    /// One redacted line: identifiers and error codes only. The decisive parts come first because
    /// the activity log keeps only the head of a long message; the full lists come last, and a
    /// list that was never collected prints as `?`.
    public var summary: String {
        var parts = ["outcome=\(outcome.rawValue)"]
        if !removed.isEmpty { parts.append("removed=\(removed.map(\.identifier).sorted().joined(separator: ","))") }
        if !failed.isEmpty { parts.append("failed=\(failed.map { "\($0.identifier):\($0.error)" }.sorted().joined(separator: ","))") }
        if let error { parts.append("error=\(error)") }
        if let registryIdentifiers, let systemIdentifiers {
            let systemOnly = Set(systemIdentifiers).subtracting(registryIdentifiers)
            if !systemOnly.isEmpty { parts.append("system_only=\(systemOnly.sorted().joined(separator: ","))") }
        }
        parts.append("registry=\(Self.listSummary(registryIdentifiers))")
        parts.append("system=\(Self.listSummary(systemIdentifiers))")
        return parts.joined(separator: " ")
    }

    private static func listSummary(_ identifiers: [String]?) -> String {
        identifiers.map { $0.sorted().joined(separator: ",") } ?? "?"
    }
}
