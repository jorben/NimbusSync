import Foundation
import CloudreveDomainKit

public enum CloudreveLocalization {
    public static let supportedLocales = AppLanguage.allCases.map(\.rawValue)
    public static func locale(for identifier: String?) -> Locale {
        AppLanguage.resolve(preferredLanguages: identifier.map { [$0] } ?? []).formattingLocale()
    }
    public static func format(bytes: Int64, locale: Locale = L10n.locale) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }
    public static func format(date: Date, locale: Locale = L10n.locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    public static func format(number: Int64, locale: Locale = L10n.locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }
}
