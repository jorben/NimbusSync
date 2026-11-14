import XCTest
import Foundation
import AppKit
import CloudreveDesignSystem
import CloudreveDomainKit
import CloudreveProductKit

/// The Settings Domains page reads these for its summary line and each card's details, so their
/// words and rules stay stable.
final class SettingsDomainsPageTests: EnglishLocalizationTestCase {
    private func domain(_ index: Int, status: DomainStatus) throws -> DomainDescriptor {
        let scope = try RemoteScope(origin: "https://cloud.example.com", accountID: "account", rootURI: "cloudreve://my/")
        var domain = DomainDescriptor(identifier: "crd-8888888\(index)-8888-4888-8888-888888888888", displayName: "Domain \(index)", scope: scope, rootRemoteID: "root\(index)", accountID: "account", secretReference: "ref")
        domain.status = status
        return domain
    }

    func testSummaryCountsSyncingUpToDateAndIssues() throws {
        let summary = SettingsDomainsSummary(domains: [try domain(0, status: .syncing), try domain(1, status: .healthy)])
        XCTAssertEqual(summary.text, "1 syncing • 1 up to date • No issues")

        let checking = SettingsDomainsSummary(domains: [try domain(0, status: .reconciling), try domain(1, status: .reconciling), try domain(2, status: .authExpired)])
        XCTAssertEqual(checking.syncing, 2)
        XCTAssertEqual(checking.text, "2 syncing • 1 needs attention")

        let troubled = SettingsDomainsSummary(domains: [try domain(0, status: .offline), try domain(1, status: .conflict)])
        XCTAssertEqual(troubled.text, "2 need attention")
    }

    func testLastSyncedReadsRelativeThenDayAndTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 15)))

        XCTAssertEqual(SettingsDomainText.lastSynced(nil, now: now, calendar: calendar), "Not synced yet")
        XCTAssertEqual(SettingsDomainText.lastSynced(now.addingTimeInterval(-20), now: now, calendar: calendar), "Last synced just now")
        XCTAssertTrue(SettingsDomainText.lastSynced(now.addingTimeInterval(-120), now: now, calendar: calendar).hasPrefix("Last synced 2 min"))

        let morning = now.addingTimeInterval(-6 * 3600)
        XCTAssertEqual(SettingsDomainText.lastSynced(morning, now: now, calendar: calendar), "Last synced Today, \(morning.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale)))")
        let yesterday = now.addingTimeInterval(-20 * 3600)
        XCTAssertEqual(SettingsDomainText.lastSynced(yesterday, now: now, calendar: calendar), "Last synced Yesterday, \(yesterday.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale)))")
        let older = now.addingTimeInterval(-5 * 24 * 3600)
        XCTAssertEqual(SettingsDomainText.lastSynced(older, now: now, calendar: calendar), "Last synced \(older.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))")
    }

    func testDisplayPathShortensOnlyTheHomeFolder() {
        XCTAssertEqual(SettingsDomainText.displayPath("/Users/ann/Library/CloudStorage/NimbusSync-data", home: "/Users/ann"), "~/Library/CloudStorage/NimbusSync-data")
        XCTAssertEqual(SettingsDomainText.displayPath("/Users/ann/Docs", home: "/Users/ann/"), "~/Docs")
        XCTAssertEqual(SettingsDomainText.displayPath("/Users/anna/Docs", home: "/Users/ann"), "/Users/anna/Docs", "a sibling folder sharing a prefix is not home")
        XCTAssertEqual(SettingsDomainText.displayPath("/Volumes/Data", home: ""), "/Volumes/Data")
    }

    func testRemotePathShowsTheBoundServerFolder() throws {
        let root = try RemoteScope(origin: "https://cloud.example.com", accountID: "account", rootURI: "cloudreve://my/")
        XCTAssertEqual(SettingsDomainText.remotePath(of: root.rootURI), "/")
        let folder = try RemoteScope(origin: "https://cloud.example.com", accountID: "account", rootURI: "/Photos/2024")
        XCTAssertEqual(SettingsDomainText.remotePath(of: folder.rootURI), "/Photos/2024")
    }

    func testHostKeepsANonDefaultPort() {
        XCTAssertEqual(SettingsDomainText.host(of: "https://cloudreve.example.com"), "cloudreve.example.com")
        XCTAssertEqual(SettingsDomainText.host(of: "https://nas.example.org:5212"), "nas.example.org:5212")
        XCTAssertEqual(SettingsDomainText.host(of: "not a url"), "not a url")
    }

    func testLastSyncedIsTheNewestOfEventCheckAndFinishedTransfer() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let finished = ProductTask(domainIdentifier: "d", title: "a.txt", direction: .upload, state: .succeeded, updatedAt: base.addingTimeInterval(300))
        let failed = ProductTask(domainIdentifier: "d", title: "b.txt", direction: .upload, state: .failed, updatedAt: base.addingTimeInterval(900))

        XCTAssertNil(ProductSnapshot.lastSynced(eventAt: nil, reconcileAt: nil, tasks: [failed]), "a failed transfer is not a sync")
        XCTAssertEqual(ProductSnapshot.lastSynced(eventAt: base, reconcileAt: base.addingTimeInterval(60), tasks: []), base.addingTimeInterval(60))
        XCTAssertEqual(ProductSnapshot.lastSynced(eventAt: base, reconcileAt: nil, tasks: [finished, failed]), base.addingTimeInterval(300))
    }

    func testConnectionDotHoverTextAddsTheTimeWhenKnown() {
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let connected = ServerConnectionDisplay(kind: .connected, since: since)
        XCTAssertEqual(ServerConnectionDot.helpText(connected, now: since), "Connected · Since \(since.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale)))")
        XCTAssertEqual(ServerConnectionDot.helpText(.notConnected), "Not connected")
    }

    func testAboutVersionAddsADistinctBuildNumber() {
        XCTAssertEqual(SettingsAboutText.version(short: "0.1.0", build: "1"), "Version 0.1.0 (1)")
        XCTAssertEqual(SettingsAboutText.version(short: "0.1.0", build: "0.1.0"), "Version 0.1.0", "a build equal to the version is not repeated")
        XCTAssertEqual(SettingsAboutText.version(short: "0.1.0", build: nil), "Version 0.1.0")
        XCTAssertEqual(SettingsAboutText.version(short: " ", build: "7"), "Build 7")
        XCTAssertEqual(SettingsAboutText.version(short: nil, build: nil), "Version unknown")
    }

    func testAppearanceFallsBackToSystem() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsDomainsPageTests.appearance"))
        defaults.removePersistentDomain(forName: "SettingsDomainsPageTests.appearance")
        XCTAssertEqual(AppAppearance.stored(in: defaults), .system)
        defaults.set("dark", forKey: AppAppearance.preferenceKey)
        XCTAssertEqual(AppAppearance.stored(in: defaults), .dark)
        defaults.set("sepia", forKey: AppAppearance.preferenceKey)
        XCTAssertEqual(AppAppearance.stored(in: defaults), .system)
        XCTAssertNil(AppAppearance.system.appearanceName)
        XCTAssertEqual(AppAppearance.light.appearanceName, .aqua)
        XCTAssertEqual(AppAppearance.dark.appearanceName, .darkAqua)
        defaults.removePersistentDomain(forName: "SettingsDomainsPageTests.appearance")
    }

    func testDockIconIsShownByDefault() throws {
        let suite = "SettingsDomainsPageTests.dockIcon"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        XCTAssertTrue(DockIconPreference.stored(in: defaults), "never set means shown")
        defaults.set(false, forKey: DockIconPreference.preferenceKey)
        XCTAssertFalse(DockIconPreference.stored(in: defaults))
        defaults.set(true, forKey: DockIconPreference.preferenceKey)
        XCTAssertTrue(DockIconPreference.stored(in: defaults))
        XCTAssertEqual(DockIconPreference.activationPolicy(showsDockIcon: true), .regular)
        XCTAssertEqual(DockIconPreference.activationPolicy(showsDockIcon: false), .accessory)
        defaults.removePersistentDomain(forName: suite)
    }

    func testDockClickTogglesMenuBarPanel() {
        let now = Date()
        XCTAssertTrue(MenuBarPanelController.shouldOpenOnToggle(isPanelVisible: false, lastDismissedAt: nil, now: now), "closed panel opens")
        XCTAssertFalse(MenuBarPanelController.shouldOpenOnToggle(isPanelVisible: true, lastDismissedAt: nil, now: now), "open panel closes")
        XCTAssertFalse(MenuBarPanelController.shouldOpenOnToggle(isPanelVisible: false, lastDismissedAt: now.addingTimeInterval(-0.1), now: now), "the click that just dismissed the panel leaves it closed")
        XCTAssertTrue(MenuBarPanelController.shouldOpenOnToggle(isPanelVisible: false, lastDismissedAt: now.addingTimeInterval(-5), now: now), "an old dismissal does not block reopening")
    }
}
