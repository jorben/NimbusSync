import Foundation

/// Finder resolves static action names in its own process. Language-specific display aliases
/// use the item's persisted-preference projection, then dispatch to the existing stable action.
public enum FinderLocalization {
    public static let languageUserInfoKey = "nimbussyncLanguage"
    public static let chineseActionSuffix = ".zh-Hans"
    public static let canonicalActionIdentifiers: Set<String> = Set([
        "check-for-updates", "keep-downloaded", "allow-automatic-freeing", "remove-download",
        "open-in-nimbussync", "resolve-conflict",
    ].map { "io.github.jorben.nimbussync.\($0)" })

    public static func canonicalActionIdentifier(_ identifier: String) -> String? {
        if canonicalActionIdentifiers.contains(identifier) { return identifier }
        guard identifier.hasSuffix(chineseActionSuffix) else { return nil }
        let canonical = String(identifier.dropLast(chineseActionSuffix.count))
        return canonicalActionIdentifiers.contains(canonical) ? canonical : nil
    }
}
