import Foundation
import XCTest
import CloudreveDomainKit

final class FinderLocalizationManifestTests: XCTestCase {
    private func extensionInfo(_ name: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Config/\(name)-Info.plist")), options: [], format: nil)
        return try XCTUnwrap((object as? [String: Any])?["NSExtension"] as? [String: Any])
    }

    func testSystemActionsSelectItemLanguageIndependentlyOfHostLanguage() throws {
        var identifiers: Set<String> = []
        var actionCount = 0
        for target in ["NimbusSyncFileProvider", "NimbusSyncFileProviderUI"] {
            let actions = try XCTUnwrap(try extensionInfo(target)["NSExtensionFileProviderActions"] as? [[String: Any]])
            for action in actions {
                actionCount += 1
                let identifier = try XCTUnwrap(action["NSExtensionFileProviderActionIdentifier"] as? String)
                let canonical = try XCTUnwrap(FinderLocalization.canonicalActionIdentifier(identifier))
                let titleKey = try XCTUnwrap(action["NSExtensionFileProviderActionName"] as? String)
                let rule = try XCTUnwrap(action["NSExtensionFileProviderActionActivationRule"] as? String)
                XCTAssertNil(action["Title"])
                let predicate = NSPredicate(format: rule)
                XCTAssertFalse(predicate.evaluate(with: ["fileproviderItems": []]))
                let chineseAlias = identifier.hasSuffix(FinderLocalization.chineseActionSuffix)
                let displayLanguage: AppLanguage = chineseAlias ? .simplifiedChinese : .english
                let englishTitleKey = "finder.action.en." + canonical.components(separatedBy: ".").last!
                let sourceTitle = L10n.text(englishTitleKey, language: .english)
                let expectedTitle = L10n.text(sourceTitle, language: displayLanguage)
                for hostLanguage in AppLanguage.allCases {
                    XCTAssertEqual(L10n.text(titleKey, language: hostLanguage), expectedTitle)
                }
                for itemLanguage in AppLanguage.allCases {
                    let userInfo: [String: Any] = ["authenticated": true, "hasConflict": true, "canManageDownloadPolicy": true, "canEvict": true, "isUploading": false, "keepDownloaded": canonical.hasSuffix("allow-automatic-freeing"), FinderLocalization.languageUserInfoKey: itemLanguage.rawValue]
                    XCTAssertEqual(predicate.evaluate(with: ["fileproviderItems": [["userInfo": userInfo]]]), itemLanguage == displayLanguage, identifier)
                }
                identifiers.insert(canonical)
            }
        }
        XCTAssertEqual(actionCount, 12)
        XCTAssertEqual(identifiers, FinderLocalization.canonicalActionIdentifiers)
    }

    func testDisplayAliasesFailClosedAndPreserveCanonicalActions() {
        for canonical in FinderLocalization.canonicalActionIdentifiers {
            XCTAssertEqual(FinderLocalization.canonicalActionIdentifier(canonical), canonical)
            XCTAssertEqual(FinderLocalization.canonicalActionIdentifier(canonical + ".zh-Hans"), canonical)
            XCTAssertNil(FinderLocalization.canonicalActionIdentifier(canonical + ".fr"))
        }
        XCTAssertNil(FinderLocalization.canonicalActionIdentifier("unrecognized.zh-Hans"))
        XCTAssertNil(FinderLocalization.canonicalActionIdentifier("io.github.jorben.nimbussync.remove-download.zh-Hans.zh-Hans"))
    }

    func testUIExtensionAndDynamicDecorationLabelsUsePlatformFormat() throws {
        XCTAssertEqual(try extensionInfo("NimbusSyncFileProviderUI")["NSExtensionPointIdentifier"] as? String, "com.apple.fileprovider-actionsui")
        let decorations = try XCTUnwrap(try extensionInfo("NimbusSyncFileProvider")["NSFileProviderDecorations"] as? [[String: Any]])
        let expected: Set<String> = ["item.userInfo.localizedConflictLabel", "item.userInfo.localizedSyncErrorLabel", "item.userInfo.localizedKeepDownloadedLabel"]
        var observed: Set<String> = []
        for decoration in decorations {
            let label = try XCTUnwrap(decoration["Label"] as? [String: Any])
            XCTAssertEqual(label["NSStringFormat"] as? String, "%@")
            observed.formUnion(try XCTUnwrap(label["NSStringFormatValues"] as? [String]))
        }
        XCTAssertEqual(observed, expected)
    }
}
