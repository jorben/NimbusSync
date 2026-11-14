import AppKit
import CloudreveDesignSystem
import CloudreveDomainKit
import CloudreveObservability
import Combine
import Sparkle
@preconcurrency import UserNotifications

/// NimbusSync's in-app updates, on Sparkle 2.
///
/// - **Feed and channels.** One appcast (Info.plist `SUFeedURL`) carries stable releases on the
///   default channel and prereleases on `beta`; `BetaUpdatesPreference` decides whether `beta`
///   is allowed.
/// - **Checks.** Sparkle checks once a day (`SUScheduledCheckInterval`), plus Check for Updates….
/// - **Reminders.** NimbusSync is a menu bar app, so a scheduled check that finds an update while
///   the user is elsewhere uses Sparkle's gentle reminders: a badge on the menu bar item, a
///   banner in the panel and, when notifications are allowed, one notification. Right after
///   launch Sparkle shows its update window directly. That window offers Install, Remind Me
///   Later and Skip This Version.
/// - **Automatic updates** (off by default) download in the background; the update installs when
///   NimbusSync quits, or at once with Restart to Update, which relaunches the app.
///
/// The Dev build, and any build without a feed or EdDSA public key, never starts Sparkle
/// (`AppUpdateConfiguration`).
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    nonisolated static let notificationIdentifier = "\(AppIdentity.baseIdentifier).update-available"
    /// `userInfo` key marking the update notification, handled by the app delegate.
    nonisolated static let notificationActionKey = "nimbusSyncAction"
    nonisolated static let notificationShowUpdateAction = "showUpdate"

    let configuration: AppUpdateConfiguration
    @Published private(set) var status: AppUpdateStatus = .none {
        didSet { onStatusChange?(status) }
    }
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var receivesBetaUpdates: Bool

    /// Mirrors `status` to the menu bar item.
    var onStatusChange: ((AppUpdateStatus) -> Void)?
    /// Whether NimbusSync's own notification switch is on.
    var notificationsAllowed: () -> Bool = { true }
    /// Runs before Restart to Update hands over to Sparkle, which quits and relaunches the app.
    var prepareForRelaunch: (() async -> Void)?

    private let defaults: UserDefaults
    private var controller: SPUStandardUpdaterController?
    private var immediateInstall: (() -> Void)?
    private var observations: [NSKeyValueObservation] = []
    private var isRelaunching = false

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        configuration = AppUpdateConfiguration(bundle: bundle)
        self.defaults = defaults
        receivesBetaUpdates = BetaUpdatesPreference.stored(in: defaults)
        super.init()
    }

    var isAvailable: Bool { controller != nil }

    /// Starts the updater once; its first scheduled check runs per Sparkle's schedule.
    func start() {
        guard controller == nil else { return }
        guard configuration.isEnabled else {
            if configuration.unavailability != .disabledForBuild {
                ActivityLog.shared.warning("update", "Updates are off: \(String(describing: configuration.unavailability!))")
            }
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.lastUpdateCheckDate = updater.lastUpdateCheckDate }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates }
            },
        ]
        do {
            try updater.start()
            ActivityLog.shared.info("update", "Updater started (beta updates \(receivesBetaUpdates ? "on" : "off"))")
        } catch {
            ActivityLog.shared.error("update", "Updater could not start: \(error.localizedDescription)")
        }
    }

    /// Check for Updates…: Sparkle shows the result (including an update already found by a
    /// scheduled check) in its own window.
    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        // Not gated on canCheckForUpdates: with a gentle reminder pending, this is what brings
        // that update's window forward.
        controller.checkForUpdates(nil)
    }

    /// The menu bar banner's action.
    func openUpdate() {
        switch status {
        case .none:
            checkForUpdates()
        case .available:
            checkForUpdates()
        case .readyToInstall:
            installAndRelaunch()
        }
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }

    func setReceivesBetaUpdates(_ enabled: Bool) {
        guard enabled != receivesBetaUpdates else { return }
        receivesBetaUpdates = enabled
        defaults.set(enabled, forKey: BetaUpdatesPreference.preferenceKey)
        ActivityLog.shared.info("update", "Beta updates \(enabled ? "on" : "off")")
        // Joining the beta looks for a prerelease now rather than at tomorrow's check. Leaving it
        // never downgrades: Sparkle only offers newer builds, so the next stable one arrives once
        // it passes the installed prerelease.
        if enabled, let updater = controller?.updater, updater.automaticallyChecksForUpdates, updater.canCheckForUpdates {
            updater.checkForUpdatesInBackground()
        }
    }

    private func installAndRelaunch() {
        guard let immediateInstall, !isRelaunching else { return }
        isRelaunching = true
        ActivityLog.shared.info("update", "Restarting to install the update")
        Task { @MainActor in
            await prepareForRelaunch?()
            immediateInstall()
            // Sparkle may be refused termination (an app-modal sheet, say); allow another try.
            isRelaunching = false
        }
    }

    private func postReminder(version: String) {
        guard notificationsAllowed() else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            // Never asks for permission: an update is not worth a prompt; the badge still shows.
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = L10n.tr("\(AppIdentity.displayName) \(version) is available")
            content.body = L10n.tr("Click to see what's new.")
            content.userInfo = [Self.notificationActionKey: Self.notificationShowUpdateAction]
            try? await center.add(UNNotificationRequest(identifier: Self.notificationIdentifier, content: content, trigger: nil))
        }
    }

    private func removeReminder() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.notificationIdentifier])
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationIdentifier])
    }

    private func clearAvailableReminder() {
        removeReminder()
        if case .available = status { status = .none }
    }
}

// MARK: - SPUUpdaterDelegate

extension AppUpdater: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        BetaUpdatesPreference.allowedChannels(receivesBetas: receivesBetaUpdates)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        ActivityLog.shared.info("update", "Found \(item.displayVersionString) (\(item.versionString))\(item.channel.map { " on \($0)" } ?? "")")
    }

    /// Automatic updates: the download is done and installs on quit. Taking over the install keeps
    /// Sparkle quiet; the badge and banner offer Restart to Update instead.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        immediateInstall = immediateInstallHandler
        removeReminder()
        status = .readyToInstall(version: item.displayVersionString)
        ActivityLog.shared.info("update", "\(item.displayVersionString) downloaded; installs on quit")
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        // "No update" ends a cycle through this path too; only real failures are worth a line.
        guard nsError.domain == SUSparkleErrorDomain, nsError.code != Int(SUError.noUpdateError.rawValue) else { return }
        ActivityLog.shared.warning("update", "Update check failed: \(nsError.localizedDescription)")
    }
}

// MARK: - SPUStandardUserDriverDelegate (gentle reminders)

extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Right after launch (or after the Mac was idle) Sparkle shows the update in front; otherwise
    /// the app reminds gently instead of opening a window behind whatever the user is doing.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !state.userInitiated, !handleShowingUpdate else { return }
        if case .readyToInstall = status { return }
        status = .available(version: update.displayVersionString)
        postReminder(version: update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        clearAvailableReminder()
    }

    func standardUserDriverWillFinishUpdateSession() {
        clearAvailableReminder()
    }
}
