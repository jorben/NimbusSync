import XCTest
import CloudreveDomainKit
import CloudreveProductKit
import CloudreveDesignSystem

final class LocalizationPresentationTests: XCTestCase {
    func testPluralPresentationForBothLanguages() {
        L10n.$languageOverride.withValue(.english) {
            XCTAssertEqual(L10n.tr("\(1) domains need a review."), "1 domain needs a review.")
            XCTAssertEqual(L10n.tr("\(2) domains need a review."), "2 domains need a review.")
            XCTAssertEqual(L10n.tr("\(1) transfers in progress"), "1 transfer in progress")
            XCTAssertEqual(L10n.tr("Syncing \(1) files"), "Syncing 1 file")
            XCTAssertEqual(L10n.tr("\(1) need attention"), "1 needs attention")
            XCTAssertEqual(L10n.tr("Latest \(1) lines"), "Latest 1 line")
        }
        L10n.$languageOverride.withValue(.simplifiedChinese) {
            XCTAssertEqual(L10n.tr("\(2) domains need a review."), "2 个同步域需要检查。")
            XCTAssertEqual(L10n.tr("\(1) transfers in progress"), "1 项传输正在进行")
            XCTAssertEqual(L10n.tr("Syncing \(1) files"), "正在同步 1 个文件")
            XCTAssertEqual(L10n.tr("Latest \(2) lines"), "最近 2 行")
        }
    }

    func testAttentionSubtitlePluralizesTheAffectedCountWhilePreservingTotal() throws {
        let scope = try RemoteScope(origin: "https://cloud.example.com", accountID: "account", rootURI: "cloudreve://my/")
        for (affected, total) in [(1, 2), (1, 3), (2, 3)] {
            let domains = (0..<total).map { index in
                var domain = DomainDescriptor(displayName: "Domain \(index)", scope: scope, rootRemoteID: "root-\(index)", accountID: "account", secretReference: "reference")
                domain.status = index < affected ? .authExpired : .healthy
                return domain
            }
            L10n.$languageOverride.withValue(.english) {
                let summary = MenuBarStatusSummary(domains: domains, activeTaskCount: 0, hasActionableConflicts: false)
                XCTAssertEqual(summary.subtitle, "\(affected) of \(total) domains \(affected == 1 ? "needs" : "need") attention")
            }
            L10n.$languageOverride.withValue(.simplifiedChinese) {
                let summary = MenuBarStatusSummary(domains: domains, activeTaskCount: 0, hasActionableConflicts: false)
                XCTAssertEqual(summary.subtitle, "\(affected) 个同步域需要处理，共 \(total) 个")
            }
        }
    }

    func testLogFolderAccessibilityLocalizesOnlyTheUnavailablePlaceholder() {
        let path = "~/Library/Logs/User 100% %@"
        L10n.$languageOverride.withValue(.simplifiedChinese) {
            XCTAssertEqual(SettingsDiagnosticsText.logFolderAccessibilityLabel(nil), "日志文件夹 不可用")
            XCTAssertEqual(SettingsDiagnosticsText.logFolderAccessibilityLabel(path), "日志文件夹 \(path)")
        }
        L10n.$languageOverride.withValue(.english) {
            XCTAssertEqual(SettingsDiagnosticsText.logFolderAccessibilityLabel(nil), "Log folder unavailable")
            XCTAssertEqual(SettingsDiagnosticsText.logFolderAccessibilityLabel(path), "Log folder \(path)")
        }
    }

    func testEveryInternalErrorCodeHasBothLanguagePresentations() {
        for language in AppLanguage.allCases {
            L10n.$languageOverride.withValue(language) {
                for code in CoreErrorCode.allCases {
                    XCTAssertNotNil(SyncErrorText.title(for: code.rawValue), code.rawValue)
                    let title = TaskDisplay.reason(for: code.rawValue)
                    XCTAssertNotEqual(title, code.rawValue)
                    if language == .simplifiedChinese {
                        XCTAssertNotNil(title.range(of: "\\p{Han}", options: .regularExpression), "Missing Chinese translation for \(code.rawValue)")
                    }
                }
            }
        }
        L10n.$languageOverride.withValue(.simplifiedChinese) {
            let expected = ["download_failed": "下载失败", "upload_failed": "上传失败", "database": "数据库错误", "unsupported_metadata": "不支持此操作", "scope_conflict": "同步域范围冲突"]
            for (code, title) in expected { XCTAssertEqual(TaskDisplay.reason(for: code), title) }
        }
        XCTAssertNil(SyncErrorText.title(for: "unrecognized server-provided message"))
    }

    func testStoredConflictCodesTranslateOnlyDuringPresentation() {
        let original = "version:1234"
        L10n.$languageOverride.withValue(.simplifiedChinese) {
            XCTAssertEqual(ProductConflictText.kind("version_conflict"), "本地和远程均有更改")
            XCTAssertEqual(ProductConflictText.summary(original), "版本 1234")
            XCTAssertEqual(ProductConflictText.summary("metadata"), "元数据已更改")
            XCTAssertEqual(ProductConflictText.summary("remote_version_unknown"), "远程版本未知")
            XCTAssertEqual(ProductConflictText.summary("server supplied text 100% %@"), "server supplied text 100% %@")
        }
        L10n.$languageOverride.withValue(.english) {
            XCTAssertEqual(ProductConflictText.summary(original), "Version 1234")
        }
        XCTAssertEqual(original, "version:1234")
    }

    func testStatusAndErrorsUseSelectedLanguageWithoutChangingCodes() throws {
        let scope = try RemoteScope(origin: "https://cloud.example.com", accountID: "account", rootURI: "cloudreve://my/")
        var domain = DomainDescriptor(displayName: "User name 100% %@", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "reference")
        domain.status = .authExpired
        let error = DomainLifecycleError.overlappingScope
        L10n.$languageOverride.withValue(.simplifiedChinese) {
            let summary = MenuBarStatusSummary(domains: [domain], activeTaskCount: 0, hasActionableConflicts: false)
            XCTAssertEqual(summary.headline, "需要你处理")
            XCTAssertTrue(summary.tooltip.contains("User name 100% %@"))
            XCTAssertEqual(TaskDisplay.reason(for: "authentication_required"), "需要登录")
            XCTAssertEqual(SyncErrorText.title(for: "awaiting_source_replay"), "等待本地副本")
            XCTAssertNil(SyncErrorText.title(for: "unrecognized server-provided message"))
            XCTAssertEqual(error.errorDescription, "此 Cloudreve 位置与现有位置重叠。")
        }
        L10n.$languageOverride.withValue(.english) {
            XCTAssertEqual(TaskDisplay.reason(for: "authentication_required"), "Sign-in required")
            XCTAssertEqual(error.errorDescription, "This Cloudreve location overlaps an existing location.")
        }
        XCTAssertEqual(error.diagnosticDescription, "overlapping_scope")
        XCTAssertEqual(domain.status, .authExpired)
    }
}
