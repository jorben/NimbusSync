import AppKit
import XCTest
import CloudreveDomainKit
import CloudreveDesignSystem

@MainActor
final class AppMenuLocalizationTests: XCTestCase {
    func testNativeApplicationCommandsRefreshWithoutChangingActionsOrShortcuts() {
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "Apple", action: nil, keyEquivalent: ""))
        let app = NSMenu()
        let host = NSMenuItem(title: "NimbusSync", action: nil, keyEquivalent: "")
        host.submenu = app
        main.addItem(host)
        let about = NSMenuItem(title: "Old About", action: Selector(("orderFrontStandardAboutPanel:")), keyEquivalent: "")
        let settings = NSMenuItem(title: "Old Settings", action: Selector(("showSettingsWindow:")), keyEquivalent: ",")
        let quit = NSMenuItem(title: "Old Quit", action: Selector(("terminate:")), keyEquivalent: "q")
        app.addItem(about)
        app.addItem(settings)
        app.addItem(quit)
        L10n.$languageOverride.withValue(.simplifiedChinese) {
            AppMenuLocalization.apply(to: main)
            XCTAssertEqual(settings.title, "设置…")
            XCTAssertEqual(quit.title, "退出 NimbusSync")
        }
        // NSApplication.mainMenu excludes the system's Apple menu in a real application.
        main.removeItem(at: 0)
        L10n.$languageOverride.withValue(.english) {
            AppMenuLocalization.apply(to: main)
            XCTAssertEqual(settings.title, "Settings…")
            XCTAssertEqual(quit.title, "Quit NimbusSync")
        }
        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertEqual(quit.action, Selector(("terminate:")))
    }
}
