import XCTest
import Foundation
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveDomainService

/// Renaming a Domain changes only its local name: identity, server binding, status,
/// credential reference and sync state stay exactly as they were.
final class DomainRenameTests: XCTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        for url in cleanup {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        cleanup.removeAll()
        super.tearDown()
    }

    private func makeStore(_ name: String) throws -> SQLiteStateStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-rename-\(name)-\(UUID().uuidString).sqlite3")
        cleanup.append(url)
        return try SQLiteStateStore(url: url)
    }

    private func descriptor(name: String, rootURI: String = "/Photos", status: DomainStatus = .healthy) throws -> DomainDescriptor {
        let scope = try RemoteScope(origin: "https://cloud.example.com", accountID: "account", rootURI: rootURI)
        var domain = DomainDescriptor(identifier: CloudreveIdentifier.domain(), displayName: name, scope: scope, rootRemoteID: "root-\(name)", accountID: "account", secretReference: "credential-\(name)")
        domain.status = status
        return domain
    }

    private actor Recorder {
        var names: [String] = []
        func record(_ name: String) { names.append(name) }
    }

    func testRenameUpdatesBothStoresAndFinderButKeepsBindingAndSyncState() async throws {
        let registry = try makeStore("registry")
        let domainStore = try makeStore("domain")
        let domain = try descriptor(name: "Work")
        try registry.registerDomain(domain)
        try domainStore.registerDomain(domain)
        let epochBefore = try domainStore.syncState().epoch
        let recorder = Recorder()
        let service = DomainRenameService(
            store: registry,
            domainStore: { _ in domainStore },
            registeredDomains: { [RegisteredDomainSnapshot(identifier: domain.identifier, displayName: "Work")] },
            updateSystemDomain: { await recorder.record($0.displayName) }
        )

        let stored = try await service.rename(descriptor: domain, to: "  Team Files  ")

        XCTAssertEqual(stored, "Team Files")
        for store in [registry, domainStore] {
            let row = try XCTUnwrap(try store.domain(identifier: domain.identifier))
            XCTAssertEqual(row.displayName, "Team Files")
            XCTAssertEqual(row.rootURI, domain.currentRootURI)
            XCTAssertEqual(row.rootRemoteID, domain.rootRemoteID)
            XCTAssertEqual(row.accountID, domain.accountID)
            XCTAssertEqual(row.secretReference, domain.secretReference)
            XCTAssertEqual(row.status, .healthy)
        }
        XCTAssertEqual(try domainStore.syncState().epoch, epochBefore, "a rename must not rotate the sync epoch")
        let names = await recorder.names
        XCTAssertEqual(names, ["Team Files"])
    }

    func testRenameRejectsInvalidDuplicateAndHeldDomains() async throws {
        let registry = try makeStore("reject")
        let work = try descriptor(name: "Work")
        let home = try descriptor(name: "Home", rootURI: "/Home")
        let held = try descriptor(name: "Held", rootURI: "/Held", status: .preservedRemoval)
        for domain in [work, home, held] { try registry.registerDomain(domain) }
        let recorder = Recorder()
        let service = DomainRenameService(
            store: registry,
            registeredDomains: { [RegisteredDomainSnapshot(identifier: "crd-stale", displayName: "Old Location")] },
            updateSystemDomain: { await recorder.record($0.displayName) }
        )

        await assertThrows(DomainProvisioningError.invalidDisplayName) { try await service.rename(descriptor: work, to: "   ") }
        await assertThrows(DomainProvisioningError.invalidDisplayName) { try await service.rename(descriptor: work, to: "bad\u{7}name") }
        await assertThrows(DomainProvisioningError.invalidDisplayName) { try await service.rename(descriptor: work, to: String(repeating: "a", count: 129)) }
        await assertThrows(DomainProvisioningError.displayNameInUse) { try await service.rename(descriptor: work, to: "home") }
        await assertThrows(DomainProvisioningError.displayNameUnavailable) { try await service.rename(descriptor: work, to: "old location") }
        await assertThrows(DomainProvisioningError.renameUnavailable) { try await service.rename(descriptor: held, to: "Kept") }

        XCTAssertEqual(try registry.domain(identifier: work.identifier)?.displayName, "Work")
        XCTAssertEqual(try registry.domain(identifier: held.identifier)?.status, .preservedRemoval)
        let names = await recorder.names
        XCTAssertTrue(names.isEmpty, "a rejected rename must not touch the Finder location")
    }

    func testRenameSkipsFinderWhenTheSystemDoesNotKnowTheDomain() async throws {
        let registry = try makeStore("unregistered")
        let domain = try descriptor(name: "Work")
        try registry.registerDomain(domain)
        let recorder = Recorder()
        let service = DomainRenameService(store: registry, registeredDomains: { [] }, updateSystemDomain: { await recorder.record($0.displayName) })

        try await service.rename(descriptor: domain, to: "Renamed")

        XCTAssertEqual(try registry.domain(identifier: domain.identifier)?.displayName, "Renamed")
        let names = await recorder.names
        XCTAssertTrue(names.isEmpty, "adding an unknown identifier would create a second Finder location")
    }

    func testFailedFinderUpdateLeavesTheStoredNameUnchanged() async throws {
        let registry = try makeStore("finder-fails")
        let domain = try descriptor(name: "Work")
        try registry.registerDomain(domain)
        let service = DomainRenameService(
            store: registry,
            registeredDomains: { [RegisteredDomainSnapshot(identifier: domain.identifier, displayName: "Work")] },
            updateSystemDomain: { _ in throw DomainProvisioningError.system("add failed") }
        )

        await assertThrows(DomainProvisioningError.system("add failed")) { try await service.rename(descriptor: domain, to: "Renamed") }
        XCTAssertEqual(try registry.domain(identifier: domain.identifier)?.displayName, "Work")
    }

    private func assertThrows(_ expected: DomainProvisioningError, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as DomainProvisioningError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}
