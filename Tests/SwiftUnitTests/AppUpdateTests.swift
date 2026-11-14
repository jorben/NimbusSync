import XCTest
import AppKit
import CloudreveDesignSystem
import CloudreveDomainKit

final class AppUpdateConfigurationTests: XCTestCase {
    private let feed = "https://jorben.github.io/NimbusSync/appcast.xml"
    private let key = "dGVzdC1wdWJsaWMta2V5LW5vdC1yZWFs"

    func testReleaseBuildWithFeedAndKeyIsEnabled() {
        let configuration = AppUpdateConfiguration(enabledFlag: "YES", feedURL: feed, publicKey: key)
        XCTAssertTrue(configuration.isEnabled)
        XCTAssertNil(configuration.unavailability)
    }

    func testDevBuildAndUnexpandedSettingStayOff() {
        XCTAssertEqual(AppUpdateConfiguration(enabledFlag: "NO", feedURL: feed, publicKey: key).unavailability, .disabledForBuild)
        XCTAssertEqual(AppUpdateConfiguration(enabledFlag: nil, feedURL: feed, publicKey: key).unavailability, .disabledForBuild)
        XCTAssertEqual(AppUpdateConfiguration(enabledFlag: "$(NIMBUSSYNC_UPDATES_ENABLED)", feedURL: feed, publicKey: key).unavailability, .disabledForBuild)
    }

    func testMissingKeyOrInsecureFeedFailsClosed() {
        XCTAssertEqual(AppUpdateConfiguration(enabledFlag: "YES", feedURL: feed, publicKey: "").unavailability, .missingPublicKey)
        XCTAssertEqual(AppUpdateConfiguration(enabledFlag: "YES", feedURL: feed, publicKey: "  \n").unavailability, .missingPublicKey)
        XCTAssertEqual(AppUpdateConfiguration(enabledFlag: "YES", feedURL: nil, publicKey: key).unavailability, .missingFeed)
        XCTAssertEqual(AppUpdateConfiguration(enabledFlag: "YES", feedURL: "http://jorben.github.io/NimbusSync/appcast.xml", publicKey: key).unavailability, .missingFeed, "the feed must be HTTPS")
    }

    func testTestRunnerBundleIsNotAnUpdater() {
        XCTAssertFalse(AppUpdateConfiguration(bundle: .main).isEnabled)
    }
}

final class BetaUpdatesPreferenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "BetaUpdatesPreferenceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testPrereleaseBuildsStartOnTheBetaChannel() {
        XCTAssertTrue(BetaUpdatesPreference.defaultValue(forVersion: "0.1.0-rc.3"))
        XCTAssertFalse(BetaUpdatesPreference.defaultValue(forVersion: "0.1.0"))
        XCTAssertFalse(BetaUpdatesPreference.defaultValue(forVersion: nil))
    }

    func testStoredChoiceWinsOverTheDefault() {
        XCTAssertTrue(BetaUpdatesPreference.stored(in: defaults, version: "1.0.0-beta.1"))
        defaults.set(false, forKey: BetaUpdatesPreference.preferenceKey)
        XCTAssertFalse(BetaUpdatesPreference.stored(in: defaults, version: "1.0.0-beta.1"))
        defaults.set(true, forKey: BetaUpdatesPreference.preferenceKey)
        XCTAssertTrue(BetaUpdatesPreference.stored(in: defaults, version: "1.0.0"))
    }

    func testAllowedChannels() {
        XCTAssertEqual(BetaUpdatesPreference.allowedChannels(receivesBetas: true), ["beta"])
        XCTAssertEqual(BetaUpdatesPreference.allowedChannels(receivesBetas: false), [], "the default channel is always allowed by Sparkle")
    }
}

final class AppUpdateStatusTests: EnglishLocalizationTestCase {
    func testBannerCopy() {
        XCTAssertNil(AppUpdateStatus.none.bannerTitle)
        XCTAssertFalse(AppUpdateStatus.none.showsBadge)

        let available = AppUpdateStatus.available(version: "0.2.0")
        XCTAssertTrue(available.showsBadge)
        XCTAssertEqual(available.bannerTitle, "\(AppIdentity.displayName) 0.2.0 is available")
        XCTAssertEqual(available.bannerActionTitle, "View")

        let ready = AppUpdateStatus.readyToInstall(version: "0.2.0")
        XCTAssertTrue(ready.showsBadge)
        XCTAssertEqual(ready.bannerActionTitle, "Restart")
        XCTAssertNotEqual(ready.bannerSymbol, available.bannerSymbol)
    }

    func testLastCheckedText() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(AppUpdateSettingsText.lastChecked(nil, now: now, locale: locale), "Never checked")
        XCTAssertEqual(AppUpdateSettingsText.lastChecked(now.addingTimeInterval(-5), now: now, locale: locale), "Last checked just now")
        XCTAssertEqual(AppUpdateSettingsText.lastChecked(now.addingTimeInterval(-2 * 3600), now: now, locale: locale), "Last checked 2 hours ago")
    }
}

@MainActor
final class MenuBarUpdateBadgeTests: EnglishLocalizationTestCase {
    private func pixels(_ image: NSImage) -> [UInt8] {
        let side = 44
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return Array(UnsafeBufferPointer(start: rep.bitmapData, count: side * side * 4))
    }

    func testBadgeKeepsTemplateAndSizeAndDrawsADot() {
        let badged = MenuBarIcon.badged(MenuBarIcon.upToDate)
        XCTAssertTrue(badged.isTemplate)
        XCTAssertEqual(badged.size, MenuBarIcon.canvas, "the status item must not change width")
        XCTAssertNotEqual(pixels(badged), pixels(MenuBarIcon.upToDate))
        XCTAssertEqual(MenuBarIcon.badgedSyncingFrames.count, MenuBarIcon.frameCount)
    }

    func testAnimatorAddsAndRemovesTheBadge() {
        let animator = MenuBarIconAnimator()
        animator.setState(.upToDate)
        animator.setTooltip("NimbusSync – Up to date")
        let plain = pixels(animator.image)

        animator.setUpdateStatus(.available(version: "0.2.0"))
        XCTAssertNotEqual(pixels(animator.image), plain)
        XCTAssertTrue(animator.accessibilityLabel.hasSuffix("Update available"))
        XCTAssertTrue(animator.tooltip.hasSuffix("Update available"))

        // A state change keeps the badge.
        animator.setState(.attention)
        XCTAssertEqual(pixels(animator.image), pixels(MenuBarIcon.badged(MenuBarIcon.attention)))

        animator.setUpdateStatus(.none)
        XCTAssertEqual(pixels(animator.image), pixels(MenuBarIcon.attention))
        XCTAssertEqual(animator.accessibilityLabel, MenuBarIconState.attention.accessibilityLabel)
        XCTAssertEqual(animator.tooltip, "NimbusSync – Up to date")
    }
}
