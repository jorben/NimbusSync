import Foundation
import Combine

/// The two languages for which NimbusSync ships complete user-facing resources.
public enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public static func resolve(preferredLanguages: [String]) -> AppLanguage {
        let supported = allCases.map(\.rawValue)
        return Bundle.preferredLocalizations(from: supported, forPreferences: preferredLanguages)
            .first.flatMap(AppLanguage.init(rawValue:)) ?? .english
    }

    /// Change the language while keeping the user's calendar, region and numbering preferences.
    public func formattingLocale(regionalLocale: Locale = .current) -> Locale {
        var components = Locale.Components(locale: regionalLocale)
        components.languageComponents = Locale.Language.Components(identifier: rawValue)
        components.languageComponents.region = regionalLocale.region
        return Locale(components: components)
    }
}

public enum AppLanguageChoice: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public var id: Self { self }

    /// Language names stay recognizable even when the user has selected the wrong language.
    public var title: String { self == .system ? L10n.tr("Follow System") : sourceTitle }

    /// Native SwiftUI pickers resolve these stable keys against their locale environment.
    public var sourceTitle: String {
        switch self {
        case .system: "Follow System"
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        switch self {
        case .system: AppLanguage.resolve(preferredLanguages: preferredLanguages)
        case .english: .english
        case .simplifiedChinese: .simplifiedChinese
        }
    }
}

/// Both extensions read this preference without contacting the main application.
public struct AppLanguagePreference {
    public static let key = "appLanguage"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public static func sharedDefaults() -> UserDefaults {
        // Never fall back to the standard defaults: that would silently split app and extension
        // preferences if the App Group is misconfigured.
        UserDefaults(suiteName: AppIdentity.appGroupIdentifier)!
    }

    public var choice: AppLanguageChoice {
        defaults.string(forKey: Self.key).flatMap(AppLanguageChoice.init(rawValue:)) ?? .system
    }

    public func store(_ choice: AppLanguageChoice) {
        defaults.set(choice.rawValue, forKey: Self.key)
    }
}

/// Native resource lookup shared by the app, its UI packages and both extensions.
public enum L10n {
    public static let resourceBundle = Bundle.module
    /// A scoped language for previews and tests; inherited by child tasks and restored on exit.
    /// Normal app and extension execution always reads the persisted shared preference.
    @TaskLocal public static var languageOverride: AppLanguage?

    public static var language: AppLanguage {
        languageOverride ?? AppLanguagePreference(defaults: AppLanguagePreference.sharedDefaults()).choice.resolved()
    }

    public static var locale: Locale { language.formattingLocale() }

    public static func bundle(for language: AppLanguage) -> Bundle {
        guard let path = resourceBundle.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return resourceBundle }
        return bundle
    }

    /// Explicitly choose the language bundle: a locale alone changes formatting, but does not
    /// override Bundle's cached localization choice after the application has launched.
    public static func tr(_ value: String.LocalizationValue, language: AppLanguage? = nil) -> String {
        let resolved = language ?? self.language
        return String(localized: value, bundle: bundle(for: resolved), locale: resolved.formattingLocale())
    }

    public static func text(_ key: String, language: AppLanguage? = nil) -> String {
        tr(String.LocalizationValue(key), language: language)
    }
}

/// SwiftUI observes this object without changing view identity, so language changes preserve
/// in-progress authorization, edited names, navigation and selections.
@MainActor
public final class AppLocalization: ObservableObject {
    public static let shared = AppLocalization(defaults: AppLanguagePreference.sharedDefaults())
    public static let didChangeNotification = Notification.Name("\(AppIdentity.baseIdentifier).languageDidChange")
    @Published public private(set) var choice: AppLanguageChoice
    @Published public private(set) var language: AppLanguage
    private let preference: AppLanguagePreference
    private var localeObserver: AnyCancellable?

    public var locale: Locale { language.formattingLocale() }

    public init(defaults: UserDefaults) {
        let preference = AppLanguagePreference(defaults: defaults)
        self.preference = preference
        choice = preference.choice
        language = preference.choice.resolved()
        localeObserver = NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
    }

    public func select(_ next: AppLanguageChoice) {
        preference.store(next)
        choice = next
        language = next.resolved()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Also called on app activation to pick up a macOS per-app language change.
    public func refresh() {
        let next = preference.choice
        choice = next
        language = next.resolved()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
