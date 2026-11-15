import XCTest
@testable import CloudreveDomainKit

final class LocalizationTests: XCTestCase {
    func testPreferredLanguageMatchingAndEnglishFallback() {
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["zh-CN"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["zh-Hans-SG"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["fr-FR", "zh-Hans"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["en-GB", "zh-CN"]), .english)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["zh-TW"]), .english)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["fr-FR"]), .english)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: []), .english)
        XCTAssertEqual(AppLanguageChoice.english.resolved(preferredLanguages: ["zh-Hans"]), .english)
        XCTAssertEqual(AppLanguageChoice.simplifiedChinese.resolved(preferredLanguages: ["en"]), .simplifiedChinese)
    }

    func testIndependentReadersSeePersistedPreferenceAndUnknownValueFollowsSystem() throws {
        let suite = "nimbussync.tests.localization.\(UUID().uuidString)"
        let writerDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { writerDefaults.removePersistentDomain(forName: suite) }
        let writer = AppLanguagePreference(defaults: writerDefaults)
        XCTAssertEqual(writer.choice, .system)
        writer.store(.simplifiedChinese)
        let reader = AppLanguagePreference(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(reader.choice, .simplifiedChinese)
        writer.store(.english)
        XCTAssertEqual(reader.choice, .english)
        writerDefaults.set("unsupported", forKey: AppLanguagePreference.key)
        XCTAssertEqual(reader.choice, .system)
    }

    func testBothNativeLanguageBundlesLoadAndFallbackUsesSourceText() {
        XCTAssertEqual(L10n.tr("Follow System", language: .english), "Follow System")
        XCTAssertEqual(L10n.tr("Follow System", language: .simplifiedChinese), "跟随系统")
        XCTAssertEqual(L10n.tr("Untranslated source fallback", language: .simplifiedChinese), "Untranslated source fallback")
        XCTAssertEqual(L10n.resourceBundle.localizations.map { $0.lowercased() }.sorted(), ["en", "zh-hans"])
        for language in AppLanguage.allCases {
            let bundle = L10n.bundle(for: language)
            XCTAssertEqual(bundle.bundleURL.pathExtension, "lproj", "Must select a language sub-bundle instead of the host-language fallback")
            XCTAssertEqual(bundle.bundleURL.deletingPathExtension().lastPathComponent.lowercased(), language.rawValue.lowercased())
        }
    }

    func testLanguageBundleLookupAcceptsPreservedAndLowercasedDirectoryNames() throws {
        for directoryName in ["zh-Hans", "zh-hans"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-language-\(UUID().uuidString).bundle")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let info = ["CFBundleDevelopmentRegion": "en"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: root.appendingPathComponent("Info.plist"))
            for (name, title) in [("en", "Follow System"), (directoryName, "跟随系统")] {
                let folder = root.appendingPathComponent("\(name).lproj")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try "\"Follow System\" = \"\(title)\";\n".write(to: folder.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
            }
            let resourceBundle = try XCTUnwrap(Bundle(url: root))
            let chinese = L10n.bundle(for: .simplifiedChinese, in: resourceBundle)
            XCTAssertEqual(chinese.bundleURL.lastPathComponent, "\(directoryName).lproj")
            XCTAssertEqual(String(localized: "Follow System", bundle: chinese, locale: Locale(identifier: "zh-Hans")), "跟随系统")
            let english = L10n.bundle(for: .english, in: resourceBundle)
            XCTAssertEqual(english.bundleURL.lastPathComponent, "en.lproj")
            XCTAssertEqual(String(localized: "Follow System", bundle: english, locale: Locale(identifier: "en")), "Follow System")
        }
    }

    func testInterpolationPreservesUserTextIncludingFormatCharacters() {
        let name = "报告 100% %@.pdf"
        XCTAssertEqual(L10n.tr("Open \(name) in Finder", language: .english), "Open 报告 100% %@.pdf in Finder")
        XCTAssertEqual(L10n.tr("Open \(name) in Finder", language: .simplifiedChinese), "在 Finder 中打开 报告 100% %@.pdf")
    }

    func testNativePluralRulesForZeroOneAndMany() {
        for count in [0, 1, 2, 100] {
            XCTAssertEqual(L10n.tr("\(count) files", language: .english), "\(count) \(count == 1 ? "file" : "files")")
            XCTAssertEqual(L10n.tr("\(count) files", language: .simplifiedChinese), "\(count) 个文件")
        }
    }

    func testScopedLanguageDoesNotModifySharedPreferences() {
        let original = AppLanguagePreference(defaults: AppLanguagePreference.sharedDefaults()).choice
        L10n.$languageOverride.withValue(.simplifiedChinese) {
            XCTAssertEqual(L10n.tr("Language"), "语言")
            L10n.$languageOverride.withValue(.english) {
                XCTAssertEqual(L10n.tr("Language"), "Language")
            }
            XCTAssertEqual(L10n.tr("Language"), "语言")
        }
        XCTAssertEqual(AppLanguagePreference(defaults: AppLanguagePreference.sharedDefaults()).choice, original)
    }

    func testNativeResourcesHaveCompleteMatchingKeysAndParameters() throws {
        var tables: [AppLanguage: [String: String]] = [:]
        for language in AppLanguage.allCases {
            let url = try XCTUnwrap(L10n.bundle(for: language).url(forResource: "Localizable", withExtension: "strings"))
            let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)
            tables[language] = try XCTUnwrap(object as? [String: String])
        }
        let english = try XCTUnwrap(tables[.english])
        let chinese = try XCTUnwrap(tables[.simplifiedChinese])
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        let placeholders = try NSRegularExpression(pattern: "%(@|lld|ld|lf|f|d)")
        func arguments(_ value: String) -> [String] {
            placeholders.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                (value as NSString).substring(with: $0.range)
            }.sorted()
        }
        for (key, translation) in chinese {
            XCTAssertFalse(translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key)
            XCTAssertEqual(arguments(key), arguments(translation), key)
        }
    }

    @MainActor
    func testObservablePreferencePersistsAndRestoresChoice() throws {
        let suite = "nimbussync.tests.language-model.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppLocalization(defaults: defaults)
        XCTAssertEqual(model.choice, .system)
        model.select(.simplifiedChinese)
        XCTAssertEqual(model.language, .simplifiedChinese)
        let restored = AppLocalization(defaults: defaults)
        XCTAssertEqual(restored.choice, .simplifiedChinese)
        restored.select(.english)
        model.refresh()
        XCTAssertEqual(model.choice, .english)
        XCTAssertEqual(model.language, .english)
    }

    func testFormattingLocaleKeepsRegionCalendarAndNumberingPreferences() {
        let regional = Locale(identifier: "en_GB@calendar=buddhist;numbers=latn")
        let translated = AppLanguage.simplifiedChinese.formattingLocale(regionalLocale: regional)
        XCTAssertEqual(translated.region, regional.region)
        XCTAssertEqual(translated.calendar.identifier, regional.calendar.identifier)
        XCTAssertEqual(translated.numberingSystem, regional.numberingSystem)
        XCTAssertEqual(translated.language.languageCode, .chinese)
    }
}
