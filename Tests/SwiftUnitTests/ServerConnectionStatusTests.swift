import XCTest
import Foundation
import CloudreveAuthKit
import CloudreveDesignSystem
import CloudreveDomainKit
import CloudreveEventCoordinator
import CloudreveStoreBridge

final class ServerConnectionStatusTests: XCTestCase {
    func testStatusKeepsTheOriginalTimeForRepeatedReports() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let connecting = DomainConnectionStatus().applying(.connecting, at: start)
        XCTAssertEqual(connecting.state, .connecting)
        XCTAssertEqual(connecting.since, start)
        XCTAssertNil(connecting.lastConnectedAt)

        let connected = connecting.applying(.subscribed, at: start.addingTimeInterval(1))
        XCTAssertEqual(connected.since, start.addingTimeInterval(1))
        XCTAssertEqual(connected.lastConnectedAt, start.addingTimeInterval(1))
        XCTAssertEqual(connected.applying(.subscribed, at: start.addingTimeInterval(60)), connected, "a repeated state is not a change")

        let dropped = connected.applying(.degraded, at: start.addingTimeInterval(90))
        XCTAssertEqual(dropped.state, .degraded)
        XCTAssertEqual(dropped.since, start.addingTimeInterval(90))
        XCTAssertEqual(dropped.lastConnectedAt, start.addingTimeInterval(1), "the last connection survives a disconnect")
    }

    func testDisplayDetailDescribesTheRelevantTime() {
        let now = Date()
        XCTAssertNil(ServerConnectionDisplay.notConnected.detail(relativeTo: now))
        XCTAssertEqual(ServerConnectionDisplay(kind: .connected, since: now).detail(relativeTo: now)?.hasPrefix("Since "), true)
        XCTAssertEqual(ServerConnectionDisplay(kind: .reconnecting, since: now, lastConnectedAt: now).detail(relativeTo: now)?.hasPrefix("Last connected "), true)
        XCTAssertNil(ServerConnectionDisplay(kind: .connecting, since: now).detail(relativeTo: now), "no connection yet, nothing to report")
    }

    func testEventRuntimeReportsOnlyConnectionStateChanges() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-connection-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "cloudreve://my/")
        let descriptor = DomainDescriptor(identifier: "crd-22222222-2222-4222-8222-222222222222", displayName: "Connection", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential-ref")
        try store.registerDomain(descriptor)
        let recorder = StateRecorder()
        let runtime = try XCTUnwrap(DomainEventRuntime(descriptor: descriptor, store: store, vault: MemoryCredentialVault(), onConnectionStateChanged: { state in
            await recorder.append(state)
        }))

        await runtime.setConnectionState(.connecting)
        await runtime.setConnectionState(.connecting)
        await runtime.setConnectionState(.degraded)
        await runtime.markAuthenticationExpired()
        await runtime.setConnectionState(.authExpired)

        let states = await recorder.states
        XCTAssertEqual(states, [.connecting, .degraded, .authExpired])
        let current = await runtime.currentConnectionState()
        XCTAssertEqual(current, .authExpired)
        let authenticationExpired = await runtime.isAuthenticationExpired()
        XCTAssertTrue(authenticationExpired)
    }
}

private actor StateRecorder {
    private(set) var states: [ConnectionState] = []
    func append(_ state: ConnectionState) { states.append(state) }
}
