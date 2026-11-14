import XCTest
import CloudreveDomainKit

/// Existing copy assertions specify English independently of the developer's macOS language
/// or the language selected in an installed NimbusSync. Never changes application preferences.
class EnglishLocalizationTestCase: XCTestCase {
    override func invokeTest() {
        L10n.$languageOverride.withValue(.english) {
            super.invokeTest()
        }
    }
}
