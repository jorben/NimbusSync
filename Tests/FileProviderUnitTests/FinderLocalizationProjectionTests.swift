import Foundation
import FileProvider
import XCTest
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveFileProviderKit

final class FinderLocalizationProjectionTests: XCTestCase {
    private func item() -> RemoteItem {
        RemoteItem(remoteID: "localized-file", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "unchanged.txt", uri: "/unchanged.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("content-v1".utf8), metadata: Data("metadata-v1".utf8)), canRead: true, canWrite: true)
    }

    func testLanguageChangesOnlyPresentationMetadataAndKeepsIdentifiersAndContentStable() {
        let model = item()
        let english = NimbusSyncFileProviderItem(model: model, hasConflict: true, language: .english)
        let chinese = NimbusSyncFileProviderItem(model: model, hasConflict: true, language: .simplifiedChinese)
        XCTAssertEqual(english.itemIdentifier, chinese.itemIdentifier)
        XCTAssertEqual(english.filename, chinese.filename)
        XCTAssertEqual(english.itemVersion.contentVersion, chinese.itemVersion.contentVersion)
        XCTAssertNotEqual(english.itemVersion.metadataVersion, chinese.itemVersion.metadataVersion)
        XCTAssertEqual(english.capabilities, chinese.capabilities)
        XCTAssertEqual(english.contentPolicy, chinese.contentPolicy)
        XCTAssertEqual(english.decorations, chinese.decorations)
        XCTAssertEqual(english.userInfo?[FinderLocalization.languageUserInfoKey] as? String, "en")
        XCTAssertEqual(chinese.userInfo?[FinderLocalization.languageUserInfoKey] as? String, "zh-Hans")
        XCTAssertEqual(english.userInfo?["localizedConflictLabel"] as? String, "Conflict")
        XCTAssertEqual(chinese.userInfo?["localizedConflictLabel"] as? String, "冲突")
        XCTAssertEqual(chinese.userInfo?["localizedSyncErrorLabel"] as? String, "同步错误")
        XCTAssertEqual(chinese.userInfo?["localizedKeepDownloadedLabel"] as? String, "保留下载")
    }

    func testLanguageRefreshPersistsOnlyAfterSignalAndDrainsPendingJobOnReversal() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-language-refresh-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let domainID = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        try store.registerDomain(DomainDescriptor(identifier: domainID, displayName: "Localization", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "reference"))
        let model = item()
        try store.insertItem(model)
        try store.setMaterialized(model.itemIdentifier, materialized: true)
        let succeeding = FrameworkCacheRefreshCoordinator(store: store, manager: nil, domainIdentifier: domainID, signalOverride: {})
        let initial = try await succeeding.refreshIfNeeded(language: .english)
        XCTAssertTrue(initial)
        XCTAssertEqual(try store.preference(key: FrameworkCacheRefreshCoordinator.languagePreferenceKey), "en")
        let failing = FrameworkCacheRefreshCoordinator(store: store, manager: nil, domainIdentifier: domainID, signalOverride: { throw CoreFailure(code: .network, retryable: true) })
        let noOp = try await failing.refreshIfNeeded(language: .english)
        XCTAssertTrue(noOp, "the same language must not signal or enqueue another refresh")

        do {
            _ = try await failing.refreshIfNeeded(language: .simplifiedChinese)
            XCTFail("signal failure must remain retryable")
        } catch {}
        XCTAssertEqual(try store.preference(key: FrameworkCacheRefreshCoordinator.languagePreferenceKey), "en")
        XCTAssertNotNil(try store.activeProjectionRefreshJob(domainIdentifier: domainID))
        let retried = try await succeeding.refreshIfNeeded(language: .simplifiedChinese)
        XCTAssertTrue(retried)
        XCTAssertEqual(try store.preference(key: FrameworkCacheRefreshCoordinator.languagePreferenceKey), "zh-Hans")

        do {
            _ = try await failing.refreshIfNeeded(language: .english)
            XCTFail("second signal failure must remain retryable")
        } catch {}
        // Returning to the saved language must still drain the failed job and pending outbox.
        let reversed = try await succeeding.refreshIfNeeded(language: .simplifiedChinese)
        XCTAssertTrue(reversed)
        XCTAssertNil(try store.activeProjectionRefreshJob(domainIdentifier: domainID))
        XCTAssertEqual(try store.pendingOutboxCount(), 0)
        XCTAssertEqual(try store.item(identifier: model.itemIdentifier)?.version.content, model.version.content)
    }
}
