import SwiftUI
import CloudreveDesignSystem
import CloudreveDomainKit
import CloudreveProductKit
import CloudreveEventCoordinator
import CloudreveFileProviderKit
import CloudreveAuthKit
import CloudreveStoreBridge
import CloudreveDomainService
import CloudreveObservability
import ServiceManagement
import AppKit
import FileProvider
import OSLog
import UserNotifications

@main
struct NimbusSyncApp: App {
    @NSApplicationDelegateAdaptor(NimbusSyncAppDelegate.self) private var appDelegate
    @StateObject private var runtime: NimbusSyncAppState

    init() {
        let runtime = NimbusSyncAppState()
        _runtime = StateObject(wrappedValue: runtime)
    }

    var body: some Scene {
        // The menu bar item and its panel are AppKit-owned (see `MenuBarPanelController`), set up
        // by the delegate for the primary instance only.
        let _ = appDelegate.configure(runtime: runtime)

        Settings {
            settingsView(runtime: runtime, appDelegate: appDelegate)
        }
    }

    private func settingsView(runtime: NimbusSyncAppState, appDelegate: NimbusSyncAppDelegate) -> some View {
        SettingsView(
            domains: runtime.snapshot.domains,
            exclusionRules: runtime.snapshot.exclusionRules,
            notificationPreferences: runtime.snapshot.notificationPreferences,
            finderError: Binding<String?>(get: { runtime.finderError }, set: { runtime.finderError = $0 }),
            finderSettingsActionAvailable: Binding(get: { runtime.finderSettingsActionAvailable }, set: { runtime.finderSettingsActionAvailable = $0 }),
            domainRemovalError: Binding<String?>(get: { runtime.domainRemovalError }, set: { runtime.domainRemovalError = $0 }),
            exclusionError: Binding<String?>(get: { runtime.exclusionError }, set: { runtime.exclusionError = $0 }),
            removingDomainIdentifier: runtime.removingDomainIdentifier,
            renamingDomainIdentifier: runtime.renamingDomainIdentifier,
            domainRenameError: Binding<String?>(get: { runtime.domainRenameError }, set: { runtime.domainRenameError = $0 }),
            reauthorizationError: Binding<String?>(get: { runtime.reauthorizationError }, set: { runtime.reauthorizationError = $0 }),
            onRename: runtime.renameDomain,
            onOpenFinder: runtime.openFinder,
            onOpenFileProviderSettings: runtime.openFileProviderSettings,
            onRemove: runtime.removeDomain,
            onFinalizeRemoval: runtime.finalizePreservedDomainRemoval,
            onOpenWeb: runtime.openWeb,
            onReauthorize: runtime.reauthorize,
            onApplyExclusionRules: runtime.applyExclusionRules,
            onNotificationsChanged: runtime.setNotificationPreferences,
            onAddDomain: { appDelegate.openOnboardingWindow() },
            connections: runtime.connectionDisplays,
            checkProgress: runtime.snapshot.checkProgress,
            checkableDomainIdentifiers: runtime.checkableDomainIdentifiers,
            onCheckNow: runtime.checkNow,
            lastSyncedAt: runtime.snapshot.lastSyncedAt,
            domainFolderPaths: runtime.domainFolderPaths,
            finderIntegration: runtime.finderIntegration,
            onRefreshFinderIntegration: runtime.refreshFinderIntegration,
            recentLogLines: runtime.recentLogLines,
            logsDirectoryPath: runtime.logsDirectoryPath,
            onOpenLogs: runtime.openLogsFolder,
            onRefresh: runtime.reload
        )
    }

}

@MainActor
private final class NimbusSyncAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    private static let forwardedURLNotification = Notification.Name("\(AppIdentity.baseIdentifier).forwarded-external-urls")
    private static let instanceLockFilename = "\(AppIdentity.baseIdentifier).instance.lock"

    private let instanceLockDescriptor: Int32?
    private var primaryApplication: NSRunningApplication?
    private var secondaryTerminationWorkItem: DispatchWorkItem?
    private var hasReceivedExternalURLs = false
    private var runtimeStarted = false
    private weak var runtime: NimbusSyncAppState?
    private var pendingExternalURLs: [URL] = []
    private var didFinishLaunching = false
    private var onboardingWindowController: NSWindowController?
    private var conflictsWindowController: NSWindowController?
    private var finderGuideWindowController: NSWindowController?
    /// The guide opens by itself at most once per run (see `FinderIntegrationPromptPolicy`).
    private var finderGuidePromptedThisRun = false
    private var menuBarPanel: MenuBarPanelController?
    private(set) var isPrimaryInstance: Bool

    override init() {
        let sharedContainer = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(AppGroupPaths.identifier, isDirectory: true)
        let lockDirectory = (AppGroupPaths.root() ?? sharedContainer)
            .appendingPathComponent("Runtime", isDirectory: true)
        try? FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let lockPath = lockDirectory.appendingPathComponent(Self.instanceLockFilename).path
        let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        if descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            instanceLockDescriptor = descriptor
            isPrimaryInstance = true
        } else {
            if descriptor >= 0 { close(descriptor) }
            instanceLockDescriptor = nil
            isPrimaryInstance = false
        }
        super.init()
        if !isPrimaryInstance {
            primaryApplication = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })
        }
        if isPrimaryInstance {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(handleForwardedURLs(_:)), name: Self.forwardedURLNotification, object: nil)
        }
    }

    func configure(runtime: NimbusSyncAppState) {
        self.runtime = runtime
        runtime.onDomainProvisioned = { [weak self] domain in
            guard let self else { return }
            onboardingWindowController?.window?.delegate = nil
            onboardingWindowController?.close()
            onboardingWindowController?.window?.delegate = self
            runtime.openFinder(domain: domain)
        }
        runtime.onFinderIntegrationChanged = { [weak self] state in
            self?.finderIntegrationChanged(state)
        }
        guard didFinishLaunching else { return }
        installMenuBarPanelIfNeeded()
        startRuntimeIfNeeded()
        drainPendingExternalURLs()
    }

    private func installMenuBarPanelIfNeeded() {
        guard isPrimaryInstance, menuBarPanel == nil, let runtime else { return }
        menuBarPanel = MenuBarPanelController(icon: runtime.menuBarIcon) {
            StatusPopoverContent(
                runtime: runtime,
                onOpenSettings: { [weak self] in self?.openFromMenuBarPanel { $0.openSettingsWindow() } },
                onAddDomain: { [weak self] in self?.openFromMenuBarPanel { $0.openOnboardingWindow() } },
                onOpenConflicts: { [weak self] in self?.openFromMenuBarPanel { $0.openConflictsWindow() } },
                onOpenFinderIntegrationGuide: { [weak self] in self?.openFromMenuBarPanel { $0.openFinderIntegrationGuide() } }
            )
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !isPrimaryInstance else {
            DockIconPreference.apply(showsDockIcon: DockIconPreference.stored())
            return
        }
        NSApp.setActivationPolicy(.prohibited)
        closeSecondaryWindows()
        primaryApplication?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard isPrimaryInstance else {
            closeSecondaryWindows()
            scheduleSecondaryTermination()
            return
        }
        UNUserNotificationCenter.current().delegate = self
        AppAppearance.stored().apply()
        didFinishLaunching = true
        installMenuBarPanelIfNeeded()
        startRuntimeIfNeeded()
        drainPendingExternalURLs()
    }

    func applicationWillTerminate(_ notification: Notification) {
        secondaryTerminationWorkItem?.cancel()
        if isPrimaryInstance {
            DistributedNotificationCenter.default().removeObserver(self)
            if let instanceLockDescriptor {
                _ = flock(instanceLockDescriptor, LOCK_UN)
                close(instanceLockDescriptor)
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isPrimaryInstance else { return }
        closeSecondaryWindows()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let value = response.notification.request.content.userInfo["deepLink"] as? String,
           let url = URL(string: value) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard isPrimaryInstance else {
            forwardExternalURLs(urls)
            return
        }
        guard runtime != nil else {
            pendingExternalURLs.append(contentsOf: urls)
            return
        }
        urls.forEach(routeExternalURL)
        application.activate(ignoringOtherApps: true)
        application.windows.first(where: \.isVisible)?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A Dock click shows or hides the menu bar panel, the same as clicking the status item.
        if isPrimaryInstance, sender.activationPolicy() == .regular {
            menuBarPanel?.toggle()
        }
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard isPrimaryInstance else { return nil }
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromDockMenu(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        return menu
    }

    @objc private func openSettingsFromDockMenu(_ sender: Any?) {
        openSettingsWindow()
    }

    /// The panel closes first, as `MenuBarExtra` did, so the window it opens is not covered.
    private func openFromMenuBarPanel(_ open: (NimbusSyncAppDelegate) -> Void) {
        menuBarPanel?.close()
        open(self)
    }

    func openSettingsWindow() {
        guard isPrimaryInstance else { return }
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        focusWindow(titled: ["\(AppIdentity.displayName) Settings", AppIdentity.displayName, "NimbusSync Settings", "NimbusSync", "Settings"], delay: .milliseconds(180), remainingAttempts: 4)
    }

    func openOnboardingWindow() {
        guard isPrimaryInstance, let runtime else { return }
        NSApp.activate(ignoringOtherApps: true)
        if onboardingWindowController == nil {
            let contentSize = NSSize(width: 580, height: 510)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: contentSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            let hostingView = NSHostingView(rootView: OnboardingWindowContent(runtime: runtime, onClose: { [weak self] in
                self?.onboardingWindowController?.close()
            }))
            hostingView.frame = NSRect(origin: .zero, size: contentSize)
            hostingView.autoresizingMask = [.width, .height]
            window.contentView = hostingView
            // The title stays for the Window menu and accessibility; the header draws its own.
            window.title = AddDomainText.windowTitle
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.delegate = self
            window.contentMinSize = NSSize(width: 520, height: 470)
            window.contentMaxSize = NSSize(width: 760, height: 680)
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindowController = NSWindowController(window: window)
        }
        onboardingWindowController?.showWindow(nil)
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === onboardingWindowController?.window else { return }
        runtime?.cancelDomainSetup()
        runtime?.onboardingOrigin = ""
    }

    func openConflictsWindow() {
        guard isPrimaryInstance, let runtime else { return }
        NSApp.activate(ignoringOtherApps: true)
        if conflictsWindowController == nil {
            let contentSize = NSSize(width: 720, height: 520)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: contentSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            let hostingView = NSHostingView(rootView: ConflictWindowContent(runtime: runtime))
            hostingView.frame = NSRect(origin: .zero, size: contentSize)
            hostingView.autoresizingMask = [.width, .height]
            window.contentView = hostingView
            window.title = "Conflicts"
            window.isReleasedWhenClosed = false
            window.center()
            conflictsWindowController = NSWindowController(window: window)
        }
        conflictsWindowController?.showWindow(nil)
        conflictsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Opens the guide by itself when Finder integration is found off, and closes it as soon as
    /// the user has turned NimbusSync on (or the last Domain is gone).
    private func finderIntegrationChanged(_ state: FinderIntegrationState) {
        switch state {
        case .on, .notSetUp:
            finderGuideWindowController?.close()
        case .off:
            guard FinderIntegrationPromptPolicy.shouldPrompt(
                state: state,
                alreadyPromptedThisRun: finderGuidePromptedThisRun,
                lastPromptedAt: FinderIntegrationPromptPolicy.lastPrompted()
            ) else { return }
            finderGuidePromptedThisRun = true
            FinderIntegrationPromptPolicy.recordPrompt()
            openFinderIntegrationGuide()
        case .unknown:
            break
        }
    }

    func openFinderIntegrationGuide() {
        guard isPrimaryInstance, let runtime else { return }
        NSApp.activate(ignoringOtherApps: true)
        if finderGuideWindowController == nil {
            let hostingView = NSHostingView(rootView: FinderIntegrationGuideView(
                onOpenSettings: { runtime.openFileProviderSettings() },
                onLater: { [weak self] in self?.finderGuideWindowController?.close() }
            ))
            let contentSize = hostingView.fittingSize
            hostingView.frame = NSRect(origin: .zero, size: contentSize)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: contentSize),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostingView
            // The title stays for the Window menu and accessibility; the view draws its own.
            window.title = FinderIntegrationGuideText.guideTitle
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.center()
            finderGuideWindowController = NSWindowController(window: window)
        }
        finderGuideWindowController?.showWindow(nil)
        finderGuideWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func startRuntimeIfNeeded() {
        guard isPrimaryInstance, !runtimeStarted, let runtime else { return }
        runtimeStarted = true
        runtime.start()
    }

    private func scheduleSecondaryTermination() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !hasReceivedExternalURLs else { return }
            NSApp.terminate(nil)
        }
        secondaryTerminationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2), execute: workItem)
    }

    private func closeSecondaryWindows() {
        guard !isPrimaryInstance else { return }
        NSApp.windows.forEach { $0.close() }
    }

    private func forwardExternalURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        hasReceivedExternalURLs = true
        secondaryTerminationWorkItem?.cancel()
        let values = urls.map(\.absoluteString)
        DistributedNotificationCenter.default().postNotificationName(
            Self.forwardedURLNotification,
            object: nil,
            userInfo: ["urls": values],
            deliverImmediately: true
        )
        primaryApplication?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.terminate(nil)
    }

    @objc private func handleForwardedURLs(_ notification: Notification) {
        guard let values = notification.userInfo?["urls"] as? [String] else { return }
        let urls = values.compactMap(URL.init(string:))
        guard !urls.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pendingExternalURLs.append(contentsOf: urls)
            NSApp.activate(ignoringOtherApps: true)
            drainPendingExternalURLs()
        }
    }

    private func focusWindow(titled titles: [String], delay: DispatchTimeInterval, remainingAttempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let window = NSApp.windows.first(where: { titles.contains($0.title) && $0.isVisible }) else {
                if remainingAttempts > 0 {
                    self?.focusWindow(
                        titled: titles,
                        delay: .milliseconds(100),
                        remainingAttempts: remainingAttempts - 1
                    )
                }
                return
            }
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true)
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private func drainPendingExternalURLs() {
        guard runtime != nil, !pendingExternalURLs.isEmpty else { return }
        let urls = pendingExternalURLs
        pendingExternalURLs.removeAll()
        urls.forEach(routeExternalURL)
    }

    private func routeExternalURL(_ url: URL) {
        guard let runtime else { pendingExternalURLs.append(url); return }
        if runtime.receiveExternalURL(url) { return }
        switch DeepLinkRouter.destination(url: url) {
        case .conflict:
            openConflictsWindow()
        case .item:
            runtime.openItem(url: url)
        case .conflictItem(let itemIdentifier):
            openConflictsWindow()
            runtime.openConflict(itemIdentifier: itemIdentifier)
        case .reauthorize(let domainIdentifier):
            // A reauthorize failure is shown by an alert in Settings; without the window it
            // would stay invisible until Settings was opened later.
            openSettingsWindow()
            runtime.openReauthorize(domainIdentifier)
        case .task, .settings:
            openSettingsWindow()
        case nil:
            break
        }
    }
}

private struct OnboardingWindowContent: View {
    @ObservedObject var runtime: NimbusSyncAppState
    let onClose: () -> Void

    var body: some View {
        AddDomainView(
            // Editing the address clears the error it caused.
            origin: Binding(
                get: { runtime.onboardingOrigin },
                set: { value in
                    if value != runtime.onboardingOrigin { runtime.onboardingError = nil }
                    runtime.onboardingOrigin = value
                }
            ),
            displayName: Binding(
                get: { runtime.pendingDomainSetup?.displayName ?? "" },
                set: { runtime.updatePendingDomainDisplayName($0) }
            ),
            authorizationPhase: runtime.authorizationPhase,
            review: runtime.pendingDomainSetup.map {
                AddDomainReview(origin: $0.origin.absoluteString, serverVersion: $0.serverVersion, remotePath: $0.remotePath)
            },
            isAdding: runtime.isProvisioningDomain,
            errorMessage: runtime.onboardingError,
            onContinue: runtime.addDomain,
            onCancelSignIn: runtime.cancelAuthorization,
            onBack: runtime.cancelDomainSetup,
            onAdd: runtime.finishDomainSetup,
            onClose: onClose,
            onOpenFileProviderSettings: runtime.openFileProviderSettings
        )
    }
}

private struct ConflictWindowContent: View {
    @ObservedObject var runtime: NimbusSyncAppState

    var body: some View {
        ConflictCenterView(
            conflicts: Binding(
                get: { runtime.snapshot.conflicts },
                set: { runtime.snapshot.conflicts = $0 }
            ),
            selectedItemIdentifier: runtime.selectedConflictItemIdentifier,
            onKeepRemote: runtime.keepRemote,
            onOverwriteRemote: runtime.prepareOverwriteRemote,
            onKeepBoth: runtime.prepareKeepBoth,
            onExportLocalCopy: runtime.exportConflictLocalCopy
        )
        .tint(NimbusSyncDesignTokens.brandColor)
        .alert("Unable to resolve conflict", isPresented: Binding(get: { runtime.conflictActionError != nil }, set: { if !$0 { runtime.conflictActionError = nil } })) {
            Button("OK", role: .cancel) { runtime.conflictActionError = nil }
        } message: {
            Text(runtime.conflictActionError ?? "The conflict could not be resolved.")
        }
    }
}

private struct StatusPopoverContent: View {
    @ObservedObject var runtime: NimbusSyncAppState
    let onOpenSettings: () -> Void
    let onAddDomain: () -> Void
    let onOpenConflicts: () -> Void
    let onOpenFinderIntegrationGuide: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MenuBarPopoverView(
                domains: runtime.snapshot.domains,
                tasks: runtime.snapshot.activeTasks.map { runtime.taskDisplay($0) },
                recentTasks: runtime.snapshot.taskProjection.recent.filter { task in
                    !runtime.snapshot.activeTasks.contains { active in active.id == task.id }
                }.map { runtime.taskDisplay($0) },
                hasActionableConflicts: !runtime.snapshot.actionableConflicts.isEmpty,
                onOpenSettings: onOpenSettings,
                onAddDomain: onAddDomain,
                onOpenConflicts: onOpenConflicts,
                onOpenDomain: runtime.openFinder,
                onCancelTask: runtime.cancelTask,
                onRetryTask: runtime.retryTask,
                onClearTask: runtime.clearTask,
                connections: runtime.connectionDisplays,
                checkProgress: runtime.snapshot.checkProgress,
                checkableDomainIdentifiers: runtime.checkableDomainIdentifiers,
                onCheckDomain: runtime.checkNow,
                onQuit: runtime.quitApplication,
                finderIntegrationOff: runtime.finderIntegration == .off,
                onOpenFinderIntegrationSettings: onOpenFinderIntegrationGuide
            )
        }
        .frame(width: NimbusSyncDesignTokens.popoverWidth)
    }
}

private struct PendingDomainSetup {
    var displayName: String
    let origin: URL
    let serverVersion: String?
    let iconURL: URL?
    let credential: Credential
    let scope: RemoteScope
    let remotePath: String
}

private enum FinderOpenError: LocalizedError {
    case provider(stage: String, domain: String, code: Int)
    case userDisabled
    case managerUnavailable
    case domainNotRegistered
    case visibleURLUnavailable
    case workspaceRejected

    var errorDescription: String? {
        switch self {
        case let .provider(stage, domain, code):
            if isDomainDisabledError(domain: domain, code: code) {
                "This domain is disabled in System Settings. Enable it under General > Login Items & Extensions > File Providers, then try again."
            } else if code == 4099 {
                "The File Provider extension exited while starting (\(domain) \(code), stage: \(stage))."
            } else if code == 513 {
                "The File Provider document storage is not writable (\(domain) \(code))."
            } else {
                "The File Provider request failed at \(stage) (\(domain) \(code))."
            }
        case .userDisabled:
            "This domain is disabled in System Settings. Enable it under General > Login Items & Extensions > File Providers, then try again."
        case .managerUnavailable:
            "The File Provider manager is unavailable."
        case .domainNotRegistered:
            "This domain is not currently registered with File Provider. Reopen NimbusSync or reconnect the domain."
        case .visibleURLUnavailable:
            "The domain does not have a Finder location yet."
        case .workspaceRejected:
            "Finder did not accept the domain location."
        }
    }
}

private func isDomainDisabledError(domain: String, code: Int) -> Bool {
    (domain == NSFileProviderErrorDomain && code == -2011) ||
        (domain == "NSFileProviderInternalErrorDomain" && code == 12)
}

private func userFacingError(_ error: Error) -> String {
    if let localized = error as? LocalizedError, let description = localized.errorDescription {
        return SecretRedactor.redact(description)
    }
    if let failure = error as? CoreFailure {
        return "NimbusSync could not complete the operation (\(failure.code.rawValue))."
    }
    let nsError = error as NSError
    return "NimbusSync could not complete the operation (\(nsError.domain):\(nsError.code))."
}

/// Plain words for what usually goes wrong while adding a Domain, falling back to the generic text.
private func onboardingErrorMessage(_ error: Error) -> String {
    if let failure = error as? CoreFailure, let message = AddDomainText.message(for: failure.code) {
        return message
    }
    if let urlError = error as? URLError, let message = AddDomainText.message(forURLError: urlError.code) {
        return message
    }
    return userFacingError(error)
}

/// A Domain's event supervisor taken out of service, with the runtime it drove.
private struct DetachedEventSupervisor: Sendable {
    let supervisor: EventSupervisor
    let runtime: DomainEventRuntime?

    /// Retires the runtime first, so a full check it is still running cannot report this
    /// stopped connection as the Domain's status once a replacement is live.
    func stop() async {
        await runtime?.retire()
        await supervisor.stop()
    }
}

private final class FinderSystemDomainBox: @unchecked Sendable {
    let domain: NSFileProviderDomain

    init(_ domain: NSFileProviderDomain) {
        self.domain = domain
    }
}

private func configuredSystemDomain(for descriptor: DomainDescriptor) -> NSFileProviderDomain {
    let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(descriptor.identifier), displayName: descriptor.displayName)
    if #available(macOS 13.0, *) {
        domain.supportsSyncingTrash = descriptor.capabilitySnapshot.canTrash
    }
    return domain
}

/// The user's real home folder; a sandboxed app's NSHomeDirectory() is its container, so paths
/// under the user's home (Finder locations, the App Group log folder) would never be shortened.
private enum UserHomeDirectory {
    static let path: String = {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: directory)
    }()
}

@MainActor
private final class NimbusSyncAppState: ObservableObject {
    @Published var snapshot = ProductSnapshot()
    @Published var isAuthorizing = false
    /// Which part of signing in the Add Domain window is waiting on; nil when it is not signing in.
    @Published var authorizationPhase: AddDomainAuthorizationPhase?
    /// The address typed in the Add Domain window, kept while the window is open so Back and a
    /// failed attempt return to it.
    @Published var onboardingOrigin = ""
    /// The running sign-in, so Cancel can stop it before the browser opens; and its attempt, so a
    /// superseded one cannot overwrite the window's state when it finally finishes.
    private var addDomainTask: Task<Void, Never>?
    private var addDomainAttempt: UUID?
    private var liveUpdateSkipReasons: [String: String] = [:]
    @Published var isProvisioningDomain = false
    @Published var onboardingError: String?
    @Published var finderError: String?
    @Published var finderSettingsActionAvailable = false
    @Published var domainRemovalError: String?
    @Published var exclusionError: String?
    @Published private(set) var removingDomainIdentifier: String?
    @Published private(set) var renamingDomainIdentifier: String?
    @Published var domainRenameError: String?
    /// Reauthorize runs from Settings or a `nimbussync://reauthorize` link; its failures are shown
    /// in Settings, not in the Add Domain window.
    @Published var reauthorizationError: String?
    /// Failures of Conflict Center actions, shown in the conflict window.
    @Published var conflictActionError: String?
    @Published fileprivate var pendingDomainSetup: PendingDomainSetup?
    @Published var selectedConflictItemIdentifier: String?
    var onDomainProvisioned: ((DomainDescriptor) -> Void)?
    /// The menu bar image: up to date, syncing (animated), paused or needs attention.
    let menuBarIcon = MenuBarIconAnimator()
    /// The newest raw log lines from the app and the File Provider extension, for Settings.
    @Published private(set) var recentLogLines: [String] = []
    nonisolated static let settingsLogLineLimit = 100
    /// Each Domain's live-update connection, keyed by Domain identifier. Only Domains that
    /// currently have an event supervisor appear here.
    @Published private(set) var connectionStatuses: [String: DomainConnectionStatus] = [:]
    /// Whether Finder shows NimbusSync's locations, as macOS reports it; re-read on Domain changes.
    /// While it is off nothing syncs, so the menu bar shows paused and the guide is offered.
    @Published private(set) var finderIntegration: FinderIntegrationState = .unknown {
        didSet {
            guard finderIntegration != oldValue else { return }
            lifecycleLogger.info("finder.integration state=\(self.finderIntegration.title, privacy: .public)")
            if finderIntegration == .off || oldValue == .off {
                ActivityLog.shared.info("lifecycle", "Finder integration \(finderIntegration.title.lowercased())")
            }
            updateMenuBarStatus()
            onFinderIntegrationChanged?(finderIntegration)
        }
    }
    /// Tells the app delegate, which owns the guide window.
    var onFinderIntegrationChanged: ((FinderIntegrationState) -> Void)?
    /// Each Domain's folder as Finder shows it, home written as "~", keyed by Domain identifier.
    @Published private(set) var domainFolderPaths: [String: String] = [:]

    private let factory = AppGroupStoreFactory()
    private let registry: SQLiteStateStore?
    private let productStore: ProductStore
    private let oauth = OAuthAuthorizationSession()
    private let oauthLogger = Logger(subsystem: AppIdentity.baseIdentifier, category: "oauth")
    private let lifecycleLogger = Logger(subsystem: AppIdentity.baseIdentifier, category: "lifecycle")
    private let heartbeat: HeartbeatCoordinator
    private let notifications: NotificationCoordinator
    private var started = false
    private var eventSupervisors: [String: EventSupervisor] = [:]
    private var eventTasks: [String: Task<Void, Never>] = [:]
    private var eventRootURIs: [String: String] = [:]
    /// Identifies the current supervisor per Domain, so a replaced one cannot report late state.
    private var eventSupervisorTokens: [String: UUID] = [:]
    /// Each Domain's event runtime, for the fallback and manual full checks.
    private var eventRuntimes: [String: DomainEventRuntime] = [:]
    private var notificationAuthorizationRequested = false
    private var isQuitting = false
    private var terminationObserver: NSObjectProtocol?
    /// Re-reads Finder integration when macOS reports a Domain change or the app comes forward,
    /// so a switch flipped in System Settings shows up while Settings is still open.
    private var finderIntegrationObservers: [NSObjectProtocol] = []
    /// Orders overlapping Finder integration reads so a slow, older one cannot overwrite a newer one.
    private var finderIntegrationGeneration = 0

    init() {
        registry = try? factory.registryStore()
        productStore = ProductStore(registry: registry, storeFactory: factory)
        heartbeat = HeartbeatCoordinator(store: registry, role: "app")
        notifications = NotificationCoordinator(preferences: productStore)
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { await self.markApplicationNotRunning() }
        }
        // macOS posts this only after getDomainsWithCompletionHandler has been called once;
        // start() and every refresh call it, so the subscription is live from launch.
        let refreshNames: [Notification.Name] = [.fileProviderDomainDidChange, NSApplication.didBecomeActiveNotification]
        finderIntegrationObservers = refreshNames.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshFinderIntegration() }
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        ActivityLog.shared.info("app", "NimbusSync \(version) started")
        reload()
        refreshFinderIntegration()
        Task { await notifications.configureCategories() }
        Task { [heartbeat] in
            while !Task.isCancelled {
                await heartbeat.beat()
                reload()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        // The extension records transfers in the shared store without notifying the app, so the
        // menu bar learns about them by polling: briskly while something is syncing, so the
        // animation stops soon after the work does, and gently otherwise.
        Task { [weak self] in
            while !Task.isCancelled {
                let syncing = self?.snapshot.isSyncing ?? false
                try? await Task.sleep(for: .seconds(syncing ? 2 : 10))
                guard let self else { return }
                self.reload()
            }
        }
        // Live updates carry everyday changes; this fallback catches what the server never
        // delivered. Each Domain counts from its own last check, so they stay spread out.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                self.startDueFallbackChecks()
            }
        }
        if let registry {
            let service = DomainRegistryService(store: registry, vault: KeychainCredentialVault(accessGroup: KeychainAccessGroup.current()), storeFactory: factory)
            Task {
                await service.recoverProvisioning()
                await logDomainInventory(service)
                reload()
            }
        }
    }

    /// Which Domains the registry and macOS each know, and what the startup cleanup did about the
    /// difference. A Domain only macOS knows keeps serving Finder from its own database with no
    /// live updates or full checks; without this line nothing would show it exists.
    private func logDomainInventory(_ service: DomainRegistryService) async {
        for row in await service.unreadableDomains() {
            lifecycleLogger.error("domain.inventory.unreadable domain=\(row.identifier, privacy: .public) status=\(row.status, privacy: .public) reason=\(row.reason, privacy: .public)")
            ActivityLog.shared.error("lifecycle", "Domain record unreadable, so it is neither listed nor synced · domain=\(row.identifier) status=\(row.status) reason=\(row.reason)")
        }
        let report = await service.removeOrphanedSystemDomains()
        let summary = report.summary
        // An empty registry with no system Domains is a fresh install with nothing to manage.
        let freshInstall = report.outcome == .registryEmpty && report.systemIdentifiers?.isEmpty == true
        if report.failed.isEmpty && (report.outcome == .checked || freshInstall) {
            lifecycleLogger.info("domain.inventory \(summary, privacy: .public)")
            ActivityLog.shared.info("lifecycle", "Domain inventory · \(summary)")
        } else {
            lifecycleLogger.error("domain.inventory \(summary, privacy: .public)")
            ActivityLog.shared.warning("lifecycle", "Domain inventory · \(summary)")
        }
    }

    func reload() {
        Task {
            let next = await productStore.snapshot()
            let previous = snapshot
            snapshot = next
            // Finder integration counts only this app's Domains, so recount when that set changes.
            if previous.domains.map(\.identifier) != next.domains.map(\.identifier) {
                refreshFinderIntegration()
            }
            updateMenuBarStatus()
            let lines = await Task.detached(priority: .utility) { ActivityLog.shared.recentLines(limit: Self.settingsLogLineLimit) }.value
            if lines != recentLogLines { recentLogLines = lines }
            syncEventSupervisors(for: next.domains)
            await notifyChanges(from: previous, to: next)
        }
    }

    /// The menu bar glyph and tooltip, from the latest snapshot and Finder integration state.
    private func updateMenuBarStatus() {
        let finderOff = finderIntegration == .off
        let conflicts = !snapshot.actionableConflicts.isEmpty
        menuBarIcon.setState(MenuBarIconState(domains: snapshot.domains, isSyncing: snapshot.isSyncing, hasActionableConflicts: conflicts, finderIntegrationOff: finderOff))
        menuBarIcon.setTooltip(MenuBarStatusSummary(domains: snapshot.domains, activeTaskCount: snapshot.activeTasks.count, hasActionableConflicts: conflicts, finderIntegrationOff: finderOff).tooltip)
    }

    private func notifyChanges(from old: ProductSnapshot, to next: ProductSnapshot) async {
        let preferences = next.notificationPreferences
        guard preferences.enabled else { return }
        if preferences.authExpired, let domain = next.domains.first(where: { $0.status == .authExpired }), old.domains.first(where: { $0.identifier == domain.identifier })?.status != .authExpired {
            await ensureNotificationPermission()
            try? await notifications.notify(kind: "auth", opaqueID: domain.identifier, title: "Authorization required", body: domain.displayName, enabled: true)
        }
        if preferences.conflicts {
            for conflict in next.actionableConflicts where !old.actionableConflicts.contains(where: { $0.id == conflict.id }) {
                await ensureNotificationPermission()
                try? await notifications.notify(kind: "conflict", opaqueID: conflict.id.uuidString, title: "Conflict needs attention", body: conflict.filename, enabled: true)
            }
        }
        if preferences.permanentFailures {
            for task in next.tasks where task.state == .failed && !old.tasks.contains(where: { $0.id == task.id && $0.state == .failed }) {
                await ensureNotificationPermission()
                try? await notifications.notify(kind: "failure", opaqueID: task.id.uuidString, title: "Action required", body: task.title, enabled: true)
            }
        }
    }

    private func ensureNotificationPermission() async {
        guard !notificationAuthorizationRequested else { return }
        notificationAuthorizationRequested = true
        _ = try? await notifications.requestAuthorizationIfNeeded()
    }

    /// Forgets a Domain's event supervisor and its connection state; the caller stops it.
    private func detachEventSupervisor(_ identifier: String) -> DetachedEventSupervisor? {
        eventTasks.removeValue(forKey: identifier)?.cancel()
        eventRootURIs.removeValue(forKey: identifier)
        eventSupervisorTokens.removeValue(forKey: identifier)
        let runtime = eventRuntimes.removeValue(forKey: identifier)
        connectionStatuses.removeValue(forKey: identifier)
        return eventSupervisors.removeValue(forKey: identifier).map { DetachedEventSupervisor(supervisor: $0, runtime: runtime) }
    }

    private func recordConnectionState(_ state: ConnectionState, domainIdentifier: String, token: UUID) {
        guard eventSupervisorTokens[domainIdentifier] == token else { return }
        let current = connectionStatuses[domainIdentifier] ?? DomainConnectionStatus()
        connectionStatuses[domainIdentifier] = current.applying(state)
    }

    private func startDueFallbackChecks() {
        let interval = FullCheckInterval.stored().seconds
        for runtime in eventRuntimes.values {
            Task { [weak self] in
                if await runtime.startFallbackCheckIfDue(interval: interval) { self?.reload() }
            }
        }
    }

    /// Whether a manual full check can start: the Domain has a live connection and is not
    /// already checking.
    func canCheckNow(_ domain: DomainDescriptor) -> Bool {
        connectionStatuses[domain.identifier] != nil && domain.status != .reconciling
    }

    func checkNow(_ domain: DomainDescriptor) {
        guard let runtime = eventRuntimes[domain.identifier] else { return }
        ActivityLog.shared.info("sync", "Full check requested by the user")
        Task { [weak self] in
            if await runtime.startManualCheck() {
                // Let the check record its run before the UI refreshes.
                try? await Task.sleep(for: .milliseconds(300))
                self?.reload()
            }
        }
    }

    var checkableDomainIdentifiers: Set<String> {
        Set(snapshot.domains.filter(canCheckNow).map(\.identifier))
    }

    var connectionDisplays: [String: ServerConnectionDisplay] {
        Dictionary(snapshot.domains.map { ($0.identifier, connectionDisplay(for: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    func connectionDisplay(for domain: DomainDescriptor) -> ServerConnectionDisplay {
        guard let status = connectionStatuses[domain.identifier] else {
            return domain.status == .authExpired ? ServerConnectionDisplay(kind: .authorizationRequired) : .notConnected
        }
        let kind: ServerConnectionDisplay.Kind = switch status.state {
        case .subscribed: .connected
        case .connecting: status.lastConnectedAt == nil ? .connecting : .reconnecting
        case .degraded: .reconnecting
        case .offline: .offline
        case .authExpired: .authorizationRequired
        case .stopped: .notConnected
        }
        return ServerConnectionDisplay(kind: kind, since: status.since, lastConnectedAt: status.lastConnectedAt)
    }

    /// Why a Domain gets no live updates or full checks, logged when the reason changes rather
    /// than on every refresh.
    private func noteLiveUpdatesSkipped(_ descriptor: DomainDescriptor, reason: String) {
        guard liveUpdateSkipReasons[descriptor.identifier] != reason else { return }
        liveUpdateSkipReasons[descriptor.identifier] = reason
        lifecycleLogger.error("domain.live_updates.skipped domain=\(descriptor.identifier, privacy: .public) reason=\(reason, privacy: .public)")
        ActivityLog.shared.warning("lifecycle", "No live updates or full checks for a domain · domain=\(descriptor.identifier) reason=\(reason)")
    }

    private func syncEventSupervisors(for domains: [DomainDescriptor]) {
        let desired = Set(domains.map(\.identifier))
        for identifier in Array(eventSupervisors.keys) where !desired.contains(identifier) {
            if let supervisor = detachEventSupervisor(identifier) { Task { await supervisor.stop() } }
        }
        liveUpdateSkipReasons = liveUpdateSkipReasons.filter { desired.contains($0.key) }
        for descriptor in domains {
            if descriptor.status.isLifecycleHold {
                if let supervisor = detachEventSupervisor(descriptor.identifier) { Task { await supervisor.stop() } }
                noteLiveUpdatesSkipped(descriptor, reason: "status_\(descriptor.status.rawValue)")
                continue
            }
            if eventSupervisors[descriptor.identifier] != nil, eventRootURIs[descriptor.identifier] != descriptor.currentRootURI,
               let supervisor = detachEventSupervisor(descriptor.identifier) {
                Task { await supervisor.stop() }
            }
            guard eventSupervisors[descriptor.identifier] == nil else { continue }
            guard let origin = URL(string: descriptor.scope.origin) else { noteLiveUpdatesSkipped(descriptor, reason: "origin"); continue }
            guard let store = try? factory.domainStore(identifier: descriptor.identifier) else { noteLiveUpdatesSkipped(descriptor, reason: "domain_store"); continue }
            guard (try? KeychainCredentialVault(accessGroup: KeychainAccessGroup.current()).read(reference: descriptor.secretReference)) != nil else { noteLiveUpdatesSkipped(descriptor, reason: "credential_missing"); continue }
            let vault = KeychainCredentialVault(accessGroup: KeychainAccessGroup.current())
            guard let clientID = try? store.ensureEventClientID() else { noteLiveUpdatesSkipped(descriptor, reason: "client_id"); continue }
            let streamFactory = CloudreveEventStreamFactory(origin: origin, uri: descriptor.currentRootURI, clientID: clientID, vault: vault, credentialReference: descriptor.secretReference)
            let identifier = descriptor.identifier
            let token = UUID()
            guard let runtime = DomainEventRuntime(descriptor: descriptor, store: store, registry: registry, vault: vault, onRootChanged: { [weak self, weak streamFactory] rootURI in
                await streamFactory?.update(uri: rootURI)
                await self?.reload()
            }, onConnectionStateChanged: { [weak self] state in
                await self?.recordConnectionState(state, domainIdentifier: identifier, token: token)
            }) else { noteLiveUpdatesSkipped(descriptor, reason: "runtime"); continue }
            liveUpdateSkipReasons[descriptor.identifier] = nil
            let supervisor = EventSupervisor(factory: streamFactory, delegate: runtime)
            eventSupervisors[descriptor.identifier] = supervisor
            eventSupervisorTokens[descriptor.identifier] = token
            eventRuntimes[descriptor.identifier] = runtime
            eventRootURIs[descriptor.identifier] = descriptor.currentRootURI
            eventTasks[descriptor.identifier] = Task { await supervisor.run() }
        }
    }

    /// Remote changes only reach Finder while the menu-bar app holds the
    /// event stream. Register the login item once, when the first location
    /// is added; a later explicit opt-out in Settings is respected.
    private func enableLaunchAtLoginOnce() {
        let key = "loginItem.autoEnabledOnce"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
            lifecycleLogger.info("login_item.registered")
        } catch {
            lifecycleLogger.error("login_item.register_failed")
        }
    }

    func addDomain(origin rawOrigin: String) {
        guard !isAuthorizing, !isProvisioningDomain else { return }
        let correlationID = UUID()
        let correlation = correlationID.uuidString.lowercased()
        onboardingError = nil
        isAuthorizing = true
        authorizationPhase = .checkingServer
        addDomainAttempt = correlationID
        oauthLogger.info("[\(correlation, privacy: .public)] oauth.add_domain.started")
        addDomainTask = Task {
            var stage = "registry"
            do {
                guard registry != nil else { throw StoreBridgeError.openFailed("App Group is unavailable") }
                stage = "site_validation"
                let site = try await SiteService().validate(origin: rawOrigin)
                oauthLogger.info("[\(correlation, privacy: .public)] oauth.site_validation.succeeded")
                // Cancelled while the server was being checked: do not open the browser.
                try Task.checkCancellation()
                let origin = site.origin
                stage = "authorization_callback"
                authorizationPhase = .waitingForBrowser
                oauthLogger.info("[\(correlation, privacy: .public)] oauth.add_domain.waiting_for_callback")
                let authorization = try await oauth.authorize(origin: origin, correlationID: correlationID)
                oauthLogger.info("[\(correlation, privacy: .public)] oauth.add_domain.callback_accepted")
                try Task.checkCancellation()
                authorizationPhase = .finishingSignIn
                stage = "token_exchange"
                let credential = try await OAuthTokenExchange().exchange(origin: origin, callback: authorization.callback, verifier: authorization.verifier, correlationID: correlationID)
                oauthLogger.info("[\(correlation, privacy: .public)] oauth.add_domain.token_exchange_succeeded")
                stage = "account_identity"
                let resolver = CloudreveIdentityResolver()
                let accountID = try await resolver.accountID(origin: origin, credential: credential)
                oauthLogger.info("[\(correlation, privacy: .public)] oauth.add_domain.account_identity_resolved")
                let requestedRoot = authorization.callback.remotePath?.isEmpty == false ? authorization.callback.remotePath! : "/"
                let scope = try RemoteScope(origin: origin.absoluteString, accountID: accountID, rootURI: requestedRoot)
                let name = authorization.callback.displayNameHint?.isEmpty == false ? authorization.callback.displayNameHint! : (site.title ?? origin.host ?? "Cloudreve")
                try Task.checkCancellation()
                pendingDomainSetup = PendingDomainSetup(
                    displayName: name,
                    origin: origin,
                    serverVersion: site.serverVersion,
                    iconURL: site.iconURL,
                    credential: credential,
                    scope: scope,
                    remotePath: requestedRoot
                )
                onboardingError = nil
            } catch {
                logOAuthFailure(error, stage: stage, correlation: correlation)
                guard addDomainAttempt == correlationID else { return }
                if error is CancellationError || error as? OAuthAuthorizationSessionError == .cancelled {
                    onboardingError = nil
                } else {
                    onboardingError = onboardingErrorMessage(error)
                }
            }
            guard addDomainAttempt == correlationID else { return }
            isAuthorizing = false
            authorizationPhase = nil
            addDomainTask = nil
        }
    }

    /// Stops signing in and returns the Add Domain window to the address, at once.
    private func abandonAuthorization() {
        addDomainTask?.cancel()
        addDomainTask = nil
        addDomainAttempt = nil
        oauth.cancel()
        isAuthorizing = false
        authorizationPhase = nil
    }

    func updatePendingDomainDisplayName(_ displayName: String) {
        pendingDomainSetup?.displayName = displayName
    }

    func finishDomainSetup() {
        guard !isProvisioningDomain, let setup = pendingDomainSetup, let registry else { return }
        isProvisioningDomain = true
        onboardingError = nil
        let correlation = UUID().uuidString.lowercased()
        Task {
            do {
                let resolver = CloudreveIdentityResolver()
                let rootURI = setup.scope.rootURI
                let service = DomainRegistryService(
                    store: registry,
                    vault: KeychainCredentialVault(accessGroup: KeychainAccessGroup.current()),
                    storeFactory: factory
                )
                let descriptor = try await service.provision(
                    displayName: setup.displayName,
                    scope: setup.scope,
                    credential: setup.credential,
                    capabilitySnapshot: .cloudreveV4(serverVersion: setup.serverVersion),
                    iconURL: setup.iconURL,
                    resolveIdentity: {
                        try await resolver.resolve(origin: setup.origin, credential: setup.credential, rootURI: rootURI)
                    },
                    firstRead: {
                        try await resolver.verifyFirstRead(origin: setup.origin, credential: setup.credential, rootURI: rootURI)
                    }
                )
                oauthLogger.info("[\(correlation, privacy: .public)] oauth.add_domain.provisioning_succeeded")
                enableLaunchAtLoginOnce()
                pendingDomainSetup = nil
                onboardingOrigin = ""
                reload()
                onDomainProvisioned?(descriptor)
            } catch {
                logOAuthFailure(error, stage: "domain_provisioning", correlation: correlation)
                onboardingError = onboardingErrorMessage(error)
            }
            isProvisioningDomain = false
        }
    }

    func cancelDomainSetup() {
        guard !isProvisioningDomain else { return }
        abandonAuthorization()
        pendingDomainSetup = nil
        onboardingError = nil
    }

    @discardableResult
    func receiveExternalURL(_ url: URL) -> Bool {
        let scheme = url.scheme ?? "missing"
        let host = url.host ?? "missing"
        oauthLogger.info("oauth.external_url.received scheme=\(scheme, privacy: .public) host=\(host, privacy: .public) path=\(url.path, privacy: .public)")
        return oauth.receiveCallback(url)
    }

    func cancelAuthorization() {
        abandonAuthorization()
        onboardingError = nil
    }

    func quitApplication() {
        guard !isQuitting else { return }
        isQuitting = true
        oauth.cancel()
        Task {
            await markApplicationNotRunning()
            NSApplication.shared.terminate(nil)
        }
    }

    private func logOAuthFailure(_ error: Error, stage: String, correlation: String) {
        if let failure = error as? DomainLifecycleError {
            oauthLogger.error("[\(correlation, privacy: .public)] oauth.add_domain.failed stage=\(stage, privacy: .public) lifecycle_error=\(failure.diagnosticDescription, privacy: .public)")
            return
        }
        if let failure = error as? DomainProvisioningError {
            oauthLogger.error("[\(correlation, privacy: .public)] oauth.add_domain.failed stage=\(stage, privacy: .public) provisioning_error=\(failure.diagnosticDescription, privacy: .public)")
            return
        }
        if let failure = error as? CoreFailure {
            oauthLogger.error("[\(correlation, privacy: .public)] oauth.add_domain.failed stage=\(stage, privacy: .public) core_code=\(failure.code.rawValue, privacy: .public) retryable=\(failure.retryable, privacy: .public)")
            return
        }
        let nsError = error as NSError
        oauthLogger.error("[\(correlation, privacy: .public)] oauth.add_domain.failed stage=\(stage, privacy: .public) error_domain=\(nsError.domain, privacy: .public) error_code=\(nsError.code, privacy: .public)")
    }

    func keepRemote(_ conflict: ProductConflict) {
        Task {
            do {
                guard let domain = snapshot.domains.first(where: { $0.identifier == conflict.domainIdentifier }), let domainStore = try? factory.domainStore(identifier: domain.identifier), let item = try domainStore.item(identifier: conflict.itemIdentifier), let origin = URL(string: domain.scope.origin) else { throw CoreFailure(code: .notFound, retryable: false) }
                let vault = KeychainCredentialVault(accessGroup: KeychainAccessGroup.current())
                let backend = NimbusSyncRemoteBackend(origin: origin, rootURI: domain.currentRootURI, store: domainStore, vault: vault, credentialReference: domain.secretReference, capabilitySnapshot: domain.capabilitySnapshot, providerName: domain.capabilitySnapshot.providers.first?.name ?? "unverified", secretVault: KeychainOpaqueSecretVault(accessGroup: KeychainAccessGroup.current()), domainIdentifier: domain.identifier)
                let projection = ConflictProjection(conflictID: conflict.id, itemIdentifier: item.itemIdentifier, kind: conflict.kind, baseSummary: conflict.baseSummary, remoteSummary: conflict.remoteSummary, localSummary: conflict.localSummary, pendingItemIdentifier: nil, sourceGeneration: 0, createdAt: conflict.createdAt, remoteVersion: conflict.remoteVersion)
                _ = try ConflictResolutionService(store: domainStore, backend: backend).keepRemote(conflict: projection)
                let systemDomain = configuredSystemDomain(for: domain)
                if let manager = NSFileProviderManager(for: systemDomain) {
                    try? await manager.signalEnumerator(for: .workingSet)
                    try? await manager.reimportItems(below: NSFileProviderItemIdentifier(item.itemIdentifier))
                }
                reload()
            } catch { conflictActionError = userFacingError(error) }
        }
    }

    func prepareOverwriteRemote(_ conflict: ProductConflict) {
        if conflict.localSourceKind == "user_export" {
            resolveConflictFromUserExport(conflict, resolution: .overwriteRemote)
        } else {
            prepareConflictResolution(conflict, resolution: .overwriteRemote)
        }
    }

    func prepareKeepBoth(_ conflict: ProductConflict) {
        if conflict.localSourceKind == "user_export" {
            resolveConflictFromUserExport(conflict, resolution: .keepBoth)
        } else {
            prepareConflictResolution(conflict, resolution: .keepBoth)
        }
    }

    func exportConflictLocalCopy(_ conflict: ProductConflict) {
        Task { @MainActor in
            do {
                guard let domain = snapshot.domains.first(where: { $0.identifier == conflict.domainIdentifier }),
                      let domainStore = try? factory.domainStore(identifier: domain.identifier) else {
                    throw CoreFailure(code: .notFound, retryable: false)
                }
                let systemDomain = configuredSystemDomain(for: domain)
                guard let manager = NSFileProviderManager(for: systemDomain) else { throw CoreFailure(code: .database, retryable: true) }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = conflict.filename
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let destination = panel.url else { return }
                let projection = ConflictProjection(conflictID: conflict.id, itemIdentifier: conflict.itemIdentifier, kind: conflict.kind, baseSummary: conflict.baseSummary, remoteSummary: conflict.remoteSummary, localSummary: conflict.localSummary, pendingItemIdentifier: conflict.itemIdentifier, sourceGeneration: conflict.sourceGeneration, createdAt: conflict.createdAt, remoteVersion: conflict.remoteVersion, localSourceKind: conflict.localSourceKind, expectedBaseVersion: conflict.expectedBaseVersion, expectedSourceHash: conflict.expectedSourceHash, expectedSourceSize: conflict.expectedSourceSize)
                _ = try await ConflictSourceExportCoordinator(store: domainStore).export(conflict: projection, manager: manager, destination: destination)
                reload()
            } catch {
                conflictActionError = userFacingError(error)
            }
        }
    }

    private func resolveConflictFromUserExport(_ conflict: ProductConflict, resolution: ConflictResolutionAction) {
        Task { @MainActor in
            do {
                guard let domain = snapshot.domains.first(where: { $0.identifier == conflict.domainIdentifier }),
                      let domainStore = try? factory.domainStore(identifier: domain.identifier),
                      try domainStore.item(identifier: conflict.itemIdentifier) != nil,
                      let origin = URL(string: domain.scope.origin) else {
                    throw CoreFailure(code: .notFound, retryable: false)
                }
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.prompt = "Use Exported Copy"
                guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
                let startedAccess = sourceURL.startAccessingSecurityScopedResource()
                defer { if startedAccess { sourceURL.stopAccessingSecurityScopedResource() } }
                let vault = KeychainCredentialVault(accessGroup: KeychainAccessGroup.current())
                let backend = NimbusSyncRemoteBackend(origin: origin, rootURI: domain.currentRootURI, store: domainStore, vault: vault, credentialReference: domain.secretReference, capabilitySnapshot: domain.capabilitySnapshot, providerName: domain.capabilitySnapshot.providers.first?.name ?? "unverified", secretVault: KeychainOpaqueSecretVault(accessGroup: KeychainAccessGroup.current()), domainIdentifier: domain.identifier)
                let projection = ConflictProjection(conflictID: conflict.id, itemIdentifier: conflict.itemIdentifier, kind: conflict.kind, baseSummary: conflict.baseSummary, remoteSummary: conflict.remoteSummary, localSummary: conflict.localSummary, pendingItemIdentifier: conflict.itemIdentifier, sourceGeneration: conflict.sourceGeneration, createdAt: conflict.createdAt, remoteVersion: conflict.remoteVersion, localSourceKind: conflict.localSourceKind, expectedBaseVersion: conflict.expectedBaseVersion, expectedSourceHash: conflict.expectedSourceHash, expectedSourceSize: conflict.expectedSourceSize)
                let service = ConflictResolutionService(store: domainStore, backend: backend)
                switch resolution {
                case .overwriteRemote: try service.prepareOverwriteRemote(conflict: projection)
                case .keepBoth: try service.prepareKeepBoth(conflict: projection)
                case .keepRemote: return
                }
                guard let manager = NSFileProviderManager(for: configuredSystemDomain(for: domain)) else { throw CoreFailure(code: .database, retryable: true) }
                let context = FileProviderOperationContext(itemIdentifier: NSFileProviderItemIdentifier(conflict.itemIdentifier), progress: Progress(totalUnitCount: 1), registrar: FileProviderManagerTaskRegistrar(manager: manager), cancellation: CancellationToken())
                let updated = try await AsyncFileProviderMutationCoordinator(store: domainStore, backend: backend).resolveConflictFromSource(conflict: projection, sourceURL: sourceURL, context: context)
                _ = updated
                try? await manager.signalEnumerator(for: .workingSet)
                try? await manager.reimportItems(below: NSFileProviderItemIdentifier(conflict.itemIdentifier))
                reload()
            } catch {
                conflictActionError = userFacingError(error)
            }
        }
    }

    private func prepareConflictResolution(_ conflict: ProductConflict, resolution: ConflictResolutionAction) {
        Task {
            do {
                guard let domain = snapshot.domains.first(where: { $0.identifier == conflict.domainIdentifier }),
                      let domainStore = try? factory.domainStore(identifier: domain.identifier),
                      let origin = URL(string: domain.scope.origin) else { throw CoreFailure(code: .notFound, retryable: false) }
                let vault = KeychainCredentialVault(accessGroup: KeychainAccessGroup.current())
                let backend = NimbusSyncRemoteBackend(origin: origin, rootURI: domain.currentRootURI, store: domainStore, vault: vault, credentialReference: domain.secretReference, capabilitySnapshot: domain.capabilitySnapshot, providerName: domain.capabilitySnapshot.providers.first?.name ?? "unverified", secretVault: KeychainOpaqueSecretVault(accessGroup: KeychainAccessGroup.current()), domainIdentifier: domain.identifier)
                let projection = ConflictProjection(conflictID: conflict.id, itemIdentifier: conflict.itemIdentifier, kind: conflict.kind, baseSummary: conflict.baseSummary, remoteSummary: conflict.remoteSummary, localSummary: conflict.localSummary, pendingItemIdentifier: conflict.itemIdentifier, sourceGeneration: conflict.sourceGeneration, createdAt: conflict.createdAt, remoteVersion: conflict.remoteVersion, localSourceKind: conflict.localSourceKind, expectedBaseVersion: conflict.expectedBaseVersion, expectedSourceHash: conflict.expectedSourceHash, expectedSourceSize: conflict.expectedSourceSize)
                let service = ConflictResolutionService(store: domainStore, backend: backend)
                switch resolution {
                case .overwriteRemote:
                    try service.prepareOverwriteRemote(conflict: projection)
                    if let manager = NSFileProviderManager(for: configuredSystemDomain(for: domain)) { try await service.requestSourceReplay(conflict: projection, manager: manager) }
                case .keepBoth:
                    try service.prepareKeepBoth(conflict: projection)
                    if let manager = NSFileProviderManager(for: configuredSystemDomain(for: domain)) { try await service.requestSourceReplay(conflict: projection, manager: manager) }
                case .keepRemote: break
                }
                let systemDomain = configuredSystemDomain(for: domain)
                if let manager = NSFileProviderManager(for: systemDomain) { try? await manager.signalEnumerator(for: .workingSet) }
                reload()
            } catch { conflictActionError = userFacingError(error) }
        }
    }


    func openItem(url: URL) {
        guard case let .item(itemIdentifier) = DeepLinkRouter.destination(url: url) else { return }
        for domain in snapshot.domains {
            guard let store = try? factory.domainStore(identifier: domain.identifier) else { continue }
            let item: RemoteItem?
            do { item = try store.item(identifier: itemIdentifier) } catch { continue }
            guard let item, let origin = URL(string: domain.scope.origin), var components = URLComponents(url: origin.appendingPathComponent("home"), resolvingAgainstBaseURL: false) else { continue }
            let folderURI = item.kind == .folder ? item.uri : (item.parentIdentifier == NSFileProviderItemIdentifier.rootContainer.rawValue ? domain.scope.rootURI : item.uri)
            let openURI = item.kind == .folder ? nil : item.uri
            components.setCloudreveQueryItems([URLQueryItem(name: "path", value: folderURI), URLQueryItem(name: "open", value: openURI)])
            guard let target = components.url else { continue }
            NSWorkspace.shared.open(target)
            return
        }
    }

    /// Reveals the newest log file (or the folder) in Finder. The folder lives in the App Group
    /// container: ~/Library/Group Containers/<AppIdentity.appGroupIdentifier>/Logs.
    var logsDirectoryPath: String? { ActivityLog.shared.directory?.path }

    func openLogsFolder() {
        guard let directory = ActivityLog.shared.directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let file = ActivityLog.shared.currentFileURL, FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(directory)
        }
    }

    func openFinder(domain: DomainDescriptor) {
        finderError = nil
        finderSettingsActionAvailable = false
        let displayName = domain.displayName
        Task { [weak self] in
            guard let self else { return }
            do {
                let systemDomain = try await self.resolveSystemDomain(for: domain)
                guard let manager = NSFileProviderManager(for: systemDomain) else {
                    throw FinderOpenError.managerUnavailable
                }
                if systemDomain.isDisconnected {
                    try await self.reconnect(manager)
                }
                let url = try await self.userVisibleURL(for: manager)
                try self.activateFinder(at: url)
                self.lifecycleLogger.info("finder.open_succeeded domain=\(domain.identifier, privacy: .public)")
            } catch {
                self.reportFinderFailure(error, displayName: displayName)
            }
        }
    }

    /// Reads which Domains macOS has registered and switched on, and where Finder shows each
    /// one. Read-only: unlike opening Finder, it never adds, migrates or reconnects a domain.
    func refreshFinderIntegration() {
        let identifiers = Set(snapshot.domains.map(\.identifier))
        finderIntegrationGeneration += 1
        let generation = finderIntegrationGeneration
        Task { [weak self] in
            guard let self else { return }
            let registered: [FinderSystemDomainBox]
            do {
                registered = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[FinderSystemDomainBox], Error>) in
                    NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: domains.map(FinderSystemDomainBox.init))
                        }
                    }
                }
            } catch {
                guard generation == self.finderIntegrationGeneration else { return }
                self.finderIntegration = .unknown
                return
            }
            guard generation == self.finderIntegrationGeneration else { return }
            let ours = registered.filter { identifiers.contains($0.domain.identifier.rawValue) }
            let enabled = ours.filter { $0.domain.userEnabled }
            let state: FinderIntegrationState = ours.isEmpty ? .notSetUp : (enabled.isEmpty ? .off : .on)
            if state != self.finderIntegration { self.finderIntegration = state }
            var paths: [String: String] = [:]
            for box in enabled {
                guard let manager = NSFileProviderManager(for: box.domain),
                      let url = try? await self.userVisibleURLOnce(for: manager) else { continue }
                paths[box.domain.identifier.rawValue] = SettingsDomainText.displayPath(url.path, home: UserHomeDirectory.path)
            }
            guard generation == self.finderIntegrationGeneration else { return }
            if paths != self.domainFolderPaths { self.domainFolderPaths = paths }
        }
    }

    private func resolveSystemDomain(for descriptor: DomainDescriptor) async throws -> NSFileProviderDomain {
        let identifier = NSFileProviderDomainIdentifier(descriptor.identifier)
        for attempt in 0..<3 {
            let registeredDomain = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FinderSystemDomainBox?, Error>) in
                NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                    if let error {
                        let nsError = error as NSError
                        continuation.resume(throwing: FinderOpenError.provider(stage: "list_domains", domain: nsError.domain, code: nsError.code))
                    } else {
                        continuation.resume(returning: domains.first(where: { $0.identifier == identifier }).map(FinderSystemDomainBox.init))
                    }
                }
            }
            if let registeredDomain {
                guard registeredDomain.domain.userEnabled else {
                    throw FinderOpenError.userDisabled
                }

                // Apple documents addDomain with the replicated initializer as
                // the migration path for an existing non-replicated record. On
                // macOS isReplicated is not a reliable way to identify old
                // records, so refresh every existing record through that path.
                let replicatedDomain = configuredSystemDomain(for: descriptor)
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    NSFileProviderManager.add(replicatedDomain) { error in
                        if let error {
                            let nsError = error as NSError
                            continuation.resume(throwing: FinderOpenError.provider(stage: "migrate_domain", domain: nsError.domain, code: nsError.code))
                        } else {
                            continuation.resume()
                        }
                    }
                }
                lifecycleLogger.info("finder.domain_migrated_to_replicated domain=\(descriptor.identifier, privacy: .public)")
                return replicatedDomain
            }
            if attempt < 2 {
                try await Task.sleep(nanoseconds: UInt64(250_000_000 * (attempt + 1)))
            }
        }
        throw FinderOpenError.domainNotRegistered
    }

    private func userVisibleURL(for manager: NSFileProviderManager) async throws -> URL {
        var lastError: FinderOpenError?
        for attempt in 0..<3 {
            do {
                return try await userVisibleURLOnce(for: manager)
            } catch let error as FinderOpenError {
                lastError = error
                if attempt < 2 {
                    try await Task.sleep(nanoseconds: UInt64(250_000_000 * (attempt + 1)))
                }
            }
        }
        throw lastError ?? FinderOpenError.visibleURLUnavailable
    }

    private func userVisibleURLOnce(for manager: NSFileProviderManager) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            manager.getUserVisibleURL(for: .rootContainer) { url, error in
                if let error {
                    let nsError = error as NSError
                    continuation.resume(throwing: FinderOpenError.provider(stage: "visible_url", domain: nsError.domain, code: nsError.code))
                } else if let url, url.isFileURL, !url.path.isEmpty {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: FinderOpenError.visibleURLUnavailable)
                }
            }
        }
    }

    private func reconnect(_ manager: NSFileProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.reconnect { error in
                if let error {
                    let nsError = error as NSError
                    continuation.resume(throwing: FinderOpenError.provider(stage: "reconnect", domain: nsError.domain, code: nsError.code))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func activateFinder(at url: URL) throws {
        let startedAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if startedAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path) else {
            throw FinderOpenError.workspaceRejected
        }
    }

    private func reportFinderFailure(_ error: Error, displayName: String) {
        if let failure = error as? FinderOpenError {
            switch failure {
            case let .provider(stage, domain, code):
                lifecycleLogger.error("finder.open_failed stage=\(stage, privacy: .public) error_domain=\(domain, privacy: .public) error_code=\(code, privacy: .public)")
                if isDomainDisabledError(domain: domain, code: code) {
                    finderSettingsActionAvailable = true
                }
            case .userDisabled:
                lifecycleLogger.error("finder.open_failed stage=domain_disabled")
                finderSettingsActionAvailable = true
            case .managerUnavailable:
                lifecycleLogger.error("finder.open_failed stage=resolve_manager")
            case .domainNotRegistered:
                lifecycleLogger.error("finder.open_failed stage=resolve_domain")
            case .visibleURLUnavailable:
                lifecycleLogger.error("finder.open_failed stage=visible_url_missing")
            case .workspaceRejected:
                lifecycleLogger.error("finder.open_failed stage=workspace_select")
            }
            finderError = "Unable to open \(displayName) in Finder. \(failure.errorDescription ?? "The File Provider location is unavailable.")"
            return
        }
        let nsError = error as NSError
        lifecycleLogger.error("finder.open_failed stage=unknown error_domain=\(nsError.domain, privacy: .public) error_code=\(nsError.code, privacy: .public)")
        finderError = "Unable to open \(displayName) in Finder. Please try again after reopening NimbusSync."
    }

    func openFileProviderSettings() {
        finderError = nil
        finderSettingsActionAvailable = false
        // macOS 15 moved File Providers from Privacy & Security › Extensions to Login Items &
        // Extensions; macOS 13 and 14 also have a Login Items pane, but without the switch.
        let loginItems = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        let extensions = "x-apple.systempreferences:com.apple.ExtensionsPreferences"
        let candidates = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15
            ? [loginItems, extensions]
            : [extensions, loginItems]
        for value in candidates {
            guard let url = URL(string: value) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    func openWeb(domain: DomainDescriptor) {
        guard let url = URL(string: domain.scope.origin) else { return }
        NSWorkspace.shared.open(url)
    }

    func applyExclusionRules(_ domain: DomainDescriptor, text: String) {
        exclusionError = nil
        Task {
            do {
                let domainStore = try factory.domainStore(identifier: domain.identifier)
                let currentRevision: UInt64
                if let encoded = try domainStore.preference(key: "exclusion.rules.\(domain.identifier)"),
                   let data = encoded.data(using: .utf8),
                   let current = try? JSONDecoder().decode(ExclusionRuleSnapshot.self, from: data) {
                    currentRevision = current.revision
                } else {
                    currentRevision = 0
                }
                guard currentRevision < UInt64.max else {
                    throw CoreFailure(code: .cannotSynchronize, retryable: false, userActionRequired: true)
                }
                let service = ExclusionApplicationService(store: domainStore)
                let application = try await service.preview(
                    revision: max(1, currentRevision + 1),
                    text: text,
                    items: try domainStore.allItems(limit: DomainScale.maximumItems),
                    rootURI: domain.currentRootURI
                )
                // Applying a view rule never deletes remote objects. When
                // dirty data is among the matches, retain it and let the
                // system/pending projection continue to surface recovery.
                let changes = try await service.apply(application, domainIdentifier: domain.identifier, preserveDirty: true)
                let systemDomain = configuredSystemDomain(for: domain)
                if let manager = NSFileProviderManager(for: systemDomain) {
                    try? await manager.signalEnumerator(for: .workingSet)
                    if changes.contains(where: { $0.kind == "view_added" }) {
                        let excludedError = FileProviderErrorMapper.map(CoreFailure(code: .excludedFromSync, retryable: false))
                        try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            manager.signalErrorResolved(excludedError) { error in
                                if let error { continuation.resume(throwing: error) }
                                else { continuation.resume() }
                            }
                        }
                    }
                }
                reload()
            } catch {
                exclusionError = userFacingError(error)
            }
        }
    }

    func removeDomain(_ domain: DomainDescriptor) {
        guard removingDomainIdentifier == nil, renamingDomainIdentifier == nil else { return }
        domainRemovalError = nil
        removingDomainIdentifier = domain.identifier
        Task {
            await resetEventSupervisor(domainIdentifier: domain.identifier)
            do {
                guard let registry else { throw StoreBridgeError.openFailed("App Group is unavailable") }
                let service = SafeDomainRemovalService(store: registry, vault: KeychainCredentialVault(accessGroup: KeychainAccessGroup.current()), storeFactory: factory)
                if let preserved = try await service.remove(descriptor: domain) {
                    domainRemovalError = "Finder removed this location, but local changes were preserved at:\n\(preserved.path)\n\nSave that copy, then choose Finish removal from the domain menu."
                }
                reload()
            } catch {
                domainRemovalError = userFacingError(error)
                reload()
            }
            removingDomainIdentifier = nil
        }
    }

    /// Renames a Domain locally and in Finder's sidebar. Identifier, server binding,
    /// credentials and sync state are unchanged, so no supervisor restart is needed.
    func renameDomain(_ domain: DomainDescriptor, to name: String) {
        guard renamingDomainIdentifier == nil, removingDomainIdentifier == nil else { return }
        domainRenameError = nil
        renamingDomainIdentifier = domain.identifier
        Task {
            do {
                guard let registry else { throw StoreBridgeError.openFailed("App Group is unavailable") }
                let factory = self.factory
                let service = DomainRenameService(store: registry, domainStore: { try factory.domainStore(identifier: $0) })
                try await service.rename(descriptor: domain, to: name)
                lifecycleLogger.info("domain.renamed domain=\(domain.identifier, privacy: .public)")
            } catch {
                domainRenameError = userFacingError(error)
            }
            renamingDomainIdentifier = nil
            reload()
            refreshFinderIntegration()
        }
    }

    func finalizePreservedDomainRemoval(_ domain: DomainDescriptor) {
        guard removingDomainIdentifier == nil, renamingDomainIdentifier == nil, domain.status == .preservedRemoval else { return }
        domainRemovalError = nil
        removingDomainIdentifier = domain.identifier
        Task {
            do {
                guard let registry else { throw StoreBridgeError.openFailed("App Group is unavailable") }
                let service = SafeDomainRemovalService(store: registry, vault: KeychainCredentialVault(accessGroup: KeychainAccessGroup.current()), storeFactory: factory)
                try await service.finalizePreservedRemoval(descriptor: domain)
                reload()
            } catch {
                domainRemovalError = userFacingError(error)
                reload()
            }
            removingDomainIdentifier = nil
        }
    }

    func reauthorize(_ domain: DomainDescriptor) {
        Task {
            do {
                guard let origin = URL(string: domain.scope.origin), let registry else { throw StoreBridgeError.openFailed("App Group is unavailable") }
                let site = try await SiteService().validate(origin: domain.scope.origin)
                let authorization = try await oauth.authorize(origin: origin)
                let exchanged = try await OAuthTokenExchange().exchange(origin: origin, callback: authorization.callback, verifier: authorization.verifier)
                let vault = KeychainCredentialVault(accessGroup: KeychainAccessGroup.current())
                let resolver = CloudreveIdentityResolver()
                let identity = try await resolver.resolve(origin: origin, credential: exchanged, rootURI: domain.currentRootURI)
                guard identity.accountID == domain.accountID, identity.rootRemoteID == domain.rootRemoteID else { throw DomainProvisioningError.accountMismatch }
                let previousGeneration = (try vault.read(reference: domain.secretReference)?.generation ?? 0)
                let credential = Credential(accessToken: exchanged.accessToken, refreshToken: exchanged.refreshToken, accessExpiry: exchanged.accessExpiry, refreshExpiry: exchanged.refreshExpiry, generation: previousGeneration + 1)
                try vault.write(credential, reference: domain.secretReference)
                try registry.setDomainStatus(identifier: domain.identifier, status: .reconciling)
                await resetEventSupervisor(domainIdentifier: domain.identifier)
                _ = site
                reload()
            } catch { reauthorizationError = userFacingError(error) }
        }
    }

    func openReauthorize(_ domainIdentifier: String) {
        guard let domain = snapshot.domains.first(where: { $0.identifier == domainIdentifier }) else { return }
        reauthorize(domain)
    }

    func openConflict(itemIdentifier: String) {
        selectedConflictItemIdentifier = itemIdentifier
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        Task {
            var preferences = await productStore.snapshot().notificationPreferences
            preferences.enabled = enabled
            try? await productStore.saveNotificationPreferences(preferences)
            reload()
        }
    }

    func setNotificationPreferences(_ preferences: NotificationPreferences) {
        Task {
            var next = preferences
            if next.enabled {
                next.enabled = (try? await notifications.requestAuthorizationIfNeeded()) ?? false
                if !next.enabled {
                    openNotificationSettings()
                }
            }
            try? await productStore.saveNotificationPreferences(next)
            reload()
        }
    }

    private func openNotificationSettings() {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? AppIdentity.baseIdentifier
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleIdentifier)") else { return }
        NSWorkspace.shared.open(url)
    }

    func cancelTask(_ taskID: UUID) {
        Task {
            try? await productStore.cancelTask(taskID)
            reload()
        }
    }

    func retryTask(_ taskID: UUID) {
        let task = snapshot.tasks.first { $0.id == taskID }
        Task {
            if let task, task.isSystemDownload {
                await requestDownloadAgain(task)
            } else {
                try? await productStore.retryTask(taskID)
            }
            reload()
        }
    }

    func clearTask(_ taskID: UUID) {
        Task {
            try? await productStore.clearTask(taskID)
            reload()
        }
    }

    /// Asks the system to download the item again, which runs the extension's fetch as if Finder
    /// had opened it. The failed record goes once the request is accepted: the new attempt keeps
    /// its own record, so a second failure is not listed twice.
    private func requestDownloadAgain(_ task: ProductTask) async {
        guard #available(macOS 14.0, *), let itemIdentifier = task.itemIdentifier,
              let domain = snapshot.domains.first(where: { $0.identifier == task.domainIdentifier }),
              let manager = NSFileProviderManager(for: configuredSystemDomain(for: domain)) else { return }
        do {
            try await manager.requestDownloadForItem(withIdentifier: NSFileProviderItemIdentifier(itemIdentifier))
            ActivityLog.shared.info("sync", "Download retry requested by the user")
            try? await productStore.clearTask(task.id)
        } catch {
            let code = (error as NSError).code
            ActivityLog.shared.warning("sync", "Download retry could not start · code=\(code)")
        }
    }

    func taskDisplay(_ task: ProductTask) -> TaskDisplay {
        let state = task.errorCode == nil ? task.state.rawValue : (task.errorCode == "unknown_outcome" || task.errorCode == "version_conflict" || task.errorCode == "authentication_required" ? "action_required" : task.state.rawValue)
        let domainName = snapshot.domains.first { $0.identifier == task.domainIdentifier }?.displayName
        return TaskDisplay(id: task.id, title: task.title, progress: task.progress, detail: task.errorCode ?? task.state.rawValue, state: state, date: task.updatedAt, domainName: domainName, retryable: task.retryable || canRequestDownload(task))
    }

    private func canRequestDownload(_ task: ProductTask) -> Bool {
        guard #available(macOS 14.0, *) else { return false }
        return task.isSystemDownload
    }

    private func resetEventSupervisor(domainIdentifier: String) async {
        if let supervisor = detachEventSupervisor(domainIdentifier) {
            await supervisor.stop()
        }
    }

    private func markApplicationNotRunning() async {
        await heartbeat.markQuit()
        for domain in snapshot.domains {
            guard !domain.status.isLifecycleHold else { continue }
            try? registry?.setDomainStatus(identifier: domain.identifier, status: .appNotRunning)
            if let store = try? factory.domainStore(identifier: domain.identifier) {
                try? store.setDomainStatus(identifier: domain.identifier, status: .appNotRunning)
            }
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case domains
    case general
    case diagnostics
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .domains: "Domains"
        case .general: "General"
        case .diagnostics: "Diagnostics"
        case .about: "About"
        }
    }

    var subtitle: String {
        switch self {
        case .domains: "Cloudreve servers synced to your Finder sidebar"
        case .general: "Startup, background checks and notifications"
        case .diagnostics: "Recent activity from NimbusSync and its Finder extension"
        case .about: "NimbusSync keeps your Cloudreve files available in Finder"
        }
    }

    var symbol: String {
        switch self {
        case .domains: "cloud"
        case .general: "gearshape"
        case .diagnostics: "waveform.path.ecg"
        case .about: "info.circle"
        }
    }

    /// ⌘1…⌘5 switch pages, as in other Mac settings windows with a sidebar.
    var shortcut: KeyEquivalent {
        KeyEquivalent(Character("\((Self.allCases.firstIndex(of: self) ?? 0) + 1)"))
    }
}

/// Shared measurements for the Settings window, so every page lines up with the Domains page.
private enum SettingsLayout {
    static let sidebarWidth: CGFloat = 228
    /// Room for the window's traffic lights above the sidebar's brand row.
    static let titlebarInset: CGFloat = 52
    static let pageInset: CGFloat = 28
    static let pageTopInset: CGFloat = 40
    static let maxContentWidth: CGFloat = 860
}

/// Where the About page points: the project and the license it ships under (see LICENSE).
private enum SettingsLinks {
    static let repository = URL(string: "https://github.com/jorben/NimbusSync")!
    static let license = URL(string: "https://github.com/jorben/NimbusSync/blob/master/LICENSE")!
}

private struct SettingsView: View {
    let domains: [DomainDescriptor]
    let exclusionRules: [String: String]
    let persistedNotificationPreferences: NotificationPreferences
    @Binding var finderError: String?
    @Binding var finderSettingsActionAvailable: Bool
    @Binding var domainRemovalError: String?
    @Binding var exclusionError: String?
    let removingDomainIdentifier: String?
    let renamingDomainIdentifier: String?
    @Binding var domainRenameError: String?
    @Binding var reauthorizationError: String?
    let onRename: (DomainDescriptor, String) -> Void
    let onOpenFinder: (DomainDescriptor) -> Void
    let onOpenFileProviderSettings: () -> Void
    let onRemove: (DomainDescriptor) -> Void
    let onFinalizeRemoval: (DomainDescriptor) -> Void
    let onOpenWeb: (DomainDescriptor) -> Void
    let onReauthorize: (DomainDescriptor) -> Void
    let onApplyExclusionRules: (DomainDescriptor, String) -> Void
    let onNotificationsChanged: (NotificationPreferences) -> Void
    let onAddDomain: () -> Void
    let connections: [String: ServerConnectionDisplay]
    let checkProgress: [String: DomainCheckProgress]
    let checkableDomainIdentifiers: Set<String>
    let onCheckNow: (DomainDescriptor) -> Void
    let lastSyncedAt: [String: Date]
    let domainFolderPaths: [String: String]
    let finderIntegration: FinderIntegrationState
    let onRefreshFinderIntegration: () -> Void
    let recentLogLines: [String]
    let logsDirectoryPath: String?
    let onOpenLogs: () -> Void
    let onRefresh: () -> Void
    @State private var selectedSection: SettingsSection = .domains
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var notificationPreferences: NotificationPreferences
    @State private var pendingRemoval: DomainDescriptor?
    @State private var editingExclusionsDomainIdentifier: String?
    @State private var copiedLogs = false
    @Environment(\.openURL) private var openURL
    @AppStorage(FullCheckInterval.preferenceKey) private var fullCheckIntervalDays = FullCheckInterval.defaultValue.rawValue
    @AppStorage(AppAppearance.preferenceKey) private var appearance = AppAppearance.system.rawValue
    @AppStorage(DockIconPreference.preferenceKey) private var showsDockIcon = DockIconPreference.defaultValue
    /// Shared with the Finder extension through the App Group's defaults.
    @AppStorage(ActivityLogLevelPreference.preferenceKey, store: ActivityLogLevelPreference.sharedDefaults()) private var logLevel = ActivityLogLevelPreference.defaultValue.rawValue

    init(domains: [DomainDescriptor], exclusionRules: [String: String], notificationPreferences: NotificationPreferences, finderError: Binding<String?>, finderSettingsActionAvailable: Binding<Bool>, domainRemovalError: Binding<String?>, exclusionError: Binding<String?>, removingDomainIdentifier: String?, renamingDomainIdentifier: String?, domainRenameError: Binding<String?>, reauthorizationError: Binding<String?>, onRename: @escaping (DomainDescriptor, String) -> Void, onOpenFinder: @escaping (DomainDescriptor) -> Void, onOpenFileProviderSettings: @escaping () -> Void, onRemove: @escaping (DomainDescriptor) -> Void, onFinalizeRemoval: @escaping (DomainDescriptor) -> Void, onOpenWeb: @escaping (DomainDescriptor) -> Void, onReauthorize: @escaping (DomainDescriptor) -> Void, onApplyExclusionRules: @escaping (DomainDescriptor, String) -> Void, onNotificationsChanged: @escaping (NotificationPreferences) -> Void, onAddDomain: @escaping () -> Void, connections: [String: ServerConnectionDisplay], checkProgress: [String: DomainCheckProgress], checkableDomainIdentifiers: Set<String>, onCheckNow: @escaping (DomainDescriptor) -> Void, lastSyncedAt: [String: Date], domainFolderPaths: [String: String], finderIntegration: FinderIntegrationState, onRefreshFinderIntegration: @escaping () -> Void, recentLogLines: [String], logsDirectoryPath: String?, onOpenLogs: @escaping () -> Void, onRefresh: @escaping () -> Void) {
        self.domains = domains
        self.exclusionRules = exclusionRules
        persistedNotificationPreferences = notificationPreferences
        _finderError = finderError
        _finderSettingsActionAvailable = finderSettingsActionAvailable
        _domainRemovalError = domainRemovalError
        _exclusionError = exclusionError
        self.removingDomainIdentifier = removingDomainIdentifier
        self.renamingDomainIdentifier = renamingDomainIdentifier
        _domainRenameError = domainRenameError
        _reauthorizationError = reauthorizationError
        self.onRename = onRename
        self.onOpenFinder = onOpenFinder
        self.onOpenFileProviderSettings = onOpenFileProviderSettings
        self.onRemove = onRemove
        self.onFinalizeRemoval = onFinalizeRemoval
        self.onOpenWeb = onOpenWeb
        self.onReauthorize = onReauthorize
        self.onApplyExclusionRules = onApplyExclusionRules
        self.onNotificationsChanged = onNotificationsChanged
        self.onAddDomain = onAddDomain
        self.connections = connections
        self.checkProgress = checkProgress
        self.checkableDomainIdentifiers = checkableDomainIdentifiers
        self.onCheckNow = onCheckNow
        self.lastSyncedAt = lastSyncedAt
        self.domainFolderPaths = domainFolderPaths
        self.finderIntegration = finderIntegration
        self.onRefreshFinderIntegration = onRefreshFinderIntegration
        self.recentLogLines = recentLogLines
        self.logsDirectoryPath = logsDirectoryPath
        self.onOpenLogs = onOpenLogs
        self.onRefresh = onRefresh
        _notificationPreferences = State(initialValue: notificationPreferences)
    }

    var body: some View {
        windowContent
        .onAppear(perform: onRefreshFinderIntegration)
        .onChange(of: domains.map(\.identifier)) { _ in onRefreshFinderIntegration() }
        .onChange(of: persistedNotificationPreferences) { value in
            notificationPreferences = value
        }
        .confirmationDialog(pendingRemoval?.status == .preservedRemoval ? "Finish removing \(pendingRemoval?.displayName ?? "domain")?" : "Remove \(pendingRemoval?.displayName ?? "domain")?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), presenting: pendingRemoval) { domain in
            if domain.status == .preservedRemoval {
                Button("I Saved the Local Copy", role: .destructive) { onFinalizeRemoval(domain); pendingRemoval = nil }
            } else {
                Button("Remove", role: .destructive) { onRemove(domain); pendingRemoval = nil }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { domain in
            if domain.status == .preservedRemoval {
                Text("Only continue after saving the local copy preserved by File Provider. NimbusSync will delete its local database and credential reference.")
            } else {
                Text("Remote files will not be deleted. Dirty local data may be preserved by File Provider.")
            }
        }
        .sheet(isPresented: Binding(get: { editingExclusionsDomainIdentifier != nil }, set: { if !$0 { editingExclusionsDomainIdentifier = nil } })) {
            if let identifier = editingExclusionsDomainIdentifier,
               let domain = domains.first(where: { $0.identifier == identifier }) {
                ExclusionRulesView(
                    initialText: exclusionRules[identifier] ?? "",
                    onApply: { text in
                        onApplyExclusionRules(domain, text)
                        editingExclusionsDomainIdentifier = nil
                    }
                )
                .frame(minWidth: 520, minHeight: 300)
            }
        }
        .alert("Unable to open Finder", isPresented: Binding(get: { finderError != nil }, set: { if !$0 { finderError = nil } })) {
            if finderSettingsActionAvailable {
                Button("Open System Settings") {
                    finderError = nil
                    finderSettingsActionAvailable = false
                    onOpenFileProviderSettings()
                }
            }
            Button("OK", role: .cancel) { finderError = nil }
        } message: {
            Text(finderError ?? "The File Provider location is unavailable.")
        }
        .alert("Domain removal", isPresented: Binding(get: { domainRemovalError != nil }, set: { if !$0 { domainRemovalError = nil } })) {
            Button("OK", role: .cancel) { domainRemovalError = nil }
        } message: {
            Text(domainRemovalError ?? "The domain could not be removed.")
        }
        .alert("Unable to rename domain", isPresented: Binding(get: { domainRenameError != nil }, set: { if !$0 { domainRenameError = nil } })) {
            Button("OK", role: .cancel) { domainRenameError = nil }
        } message: {
            Text(domainRenameError ?? "The domain could not be renamed.")
        }
        .alert("Unable to reauthorize", isPresented: Binding(get: { reauthorizationError != nil }, set: { if !$0 { reauthorizationError = nil } })) {
            Button("OK", role: .cancel) { reauthorizationError = nil }
        } message: {
            Text(reauthorizationError ?? "The domain could not be reauthorized.")
        }
        .alert("Unable to update exclusions", isPresented: Binding(get: { exclusionError != nil }, set: { if !$0 { exclusionError = nil } })) {
            Button("OK", role: .cancel) { exclusionError = nil }
        } message: {
            Text(exclusionError ?? "The exclusion rules could not be applied.")
        }
    }

    /// The sidebar and the selected page, laid out under the transparent title bar.
    private var windowContent: some View {
        HStack(alignment: .top, spacing: 0) {
            SettingsSidebar(
                selectedSection: $selectedSection,
                domainCount: domains.count,
                finderIntegration: finderIntegration,
                onOpenFileProviderSettings: onOpenFileProviderSettings
            )
            .frame(width: SettingsLayout.sidebarWidth)

            Divider()

            detailView
                .id(selectedSection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea(.container, edges: .top)
        // Without this SwiftUI turns the title bar opaque again as soon as a scroll view is on
        // screen, covering the sidebar's top with a separate band.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(SettingsWindowChrome())
        .frame(minWidth: 820, idealWidth: 960, minHeight: 560, idealHeight: 660)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(NimbusSyncDesignTokens.brandColor)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .domains:
            domainsPage
        case .general:
            generalPage
                .onAppear { onNotificationsChanged(notificationPreferences) }
        case .diagnostics:
            diagnosticsPage
                .onAppear(perform: onRefresh)
        case .about:
            aboutPage
        }
    }

    // MARK: General page

    private var generalPage: some View {
        SettingsPage(section: .general) {
            SettingsGroup("Appearance") {
                SettingsRow(symbol: "circle.lefthalf.filled", tint: .indigo, title: "Theme", subtitle: "Applies to Settings and the menu bar window.") {
                    Picker("Theme", selection: Binding(
                        get: { AppAppearance(rawValue: appearance) ?? .system },
                        set: { choice in
                            appearance = choice.rawValue
                            choice.apply()
                        }
                    )) {
                        ForEach(AppAppearance.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsGroup("Startup") {
                SettingsRow(symbol: "power", tint: .green, title: "Launch at login", subtitle: "NimbusSync stays in the menu bar so Finder integration is ready when you need it.") {
                    SettingsSwitch("Launch NimbusSync at login", isOn: Binding(get: { launchAtLogin }, set: { enabled in
                        launchAtLogin = enabled
                        try? (enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister())
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }))
                }
                SettingsRowDivider()
                SettingsRow(symbol: "dock.rectangle", tint: .blue, title: "Show icon in Dock", subtitle: "When off, NimbusSync lives only in the menu bar.") {
                    SettingsSwitch("Show NimbusSync icon in Dock", isOn: Binding(get: { showsDockIcon }, set: { shown in
                        showsDockIcon = shown
                        DockIconPreference.apply(showsDockIcon: shown)
                    }))
                }
            }

            SettingsGroup("Full check") {
                SettingsRow(symbol: "arrow.triangle.2.circlepath", title: "Background full check", subtitle: "How often every file is compared with the server.") {
                    Picker("Background full check", selection: Binding(
                        get: { FullCheckInterval(rawValue: fullCheckIntervalDays) ?? FullCheckInterval.defaultValue },
                        set: { fullCheckIntervalDays = $0.rawValue }
                    )) {
                        ForEach(FullCheckInterval.allCases) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            } footer: {
                Text("Catches anything live updates missed, at some cost in network and battery. To check a domain now, choose Full check now from its More menu.")
            }

            SettingsGroup("Notifications") {
                SettingsRow(symbol: "bell.badge", tint: .red, title: "Allow notifications", subtitle: "Tell me when a domain needs my attention.") {
                    SettingsSwitch("Allow notifications", isOn: notificationBinding(\.enabled))
                }
                SettingsRowDivider()
                Group {
                    SettingsRow(title: "Authorization required", isNested: true) {
                        SettingsSwitch("Authorization required", isOn: notificationBinding(\.authExpired))
                    }
                    SettingsRowDivider()
                    SettingsRow(title: "Conflicts", isNested: true) {
                        SettingsSwitch("Conflicts", isOn: notificationBinding(\.conflicts))
                    }
                    SettingsRowDivider()
                    SettingsRow(title: "Permanent failures", isNested: true) {
                        SettingsSwitch("Permanent failures", isOn: notificationBinding(\.permanentFailures))
                    }
                }
                .disabled(!notificationPreferences.enabled)
            } footer: {
                HStack(alignment: .firstTextBaseline, spacing: NimbusSyncDesignTokens.spacing8) {
                    Text("Notifications are delivered by macOS.")
                    Button("Notification Settings…", action: openNotificationSettings)
                        .buttonStyle(.link)
                }
            }
        }
    }

    private func openNotificationSettings() {
        var components = URLComponents(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        if let identifier = Bundle.main.bundleIdentifier {
            components.queryItems = [URLQueryItem(name: "id", value: identifier)]
        }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    // MARK: Diagnostics page

    private var diagnosticsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(section: .diagnostics)

            SettingsCard {
                logCardHeader
                Divider()
                LogTextView(lines: recentLogLines, height: nil, framed: false)
            }
            .frame(maxWidth: SettingsLayout.maxContentWidth, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, SettingsLayout.pageInset)
            .padding(.top, 4)
            .padding(.bottom, SettingsLayout.pageInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The log card's top: what is shown and where it lives, with Copy and Show in Finder on the
    /// right — the Domains card's header and actions at log size.
    private var logCardHeader: some View {
        HStack(alignment: .center, spacing: NimbusSyncDesignTokens.spacing12) {
            SettingsIconTile(symbol: "doc.text", size: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: NimbusSyncDesignTokens.spacing8) {
                    Text("Logs")
                        .font(.system(size: 15, weight: .semibold))
                    if !recentLogLines.isEmpty {
                        SettingsTagBadge("Latest \(recentLogLines.count) lines")
                    }
                }
                Text(logsDirectoryPath.map { SettingsDomainText.displayPath($0, home: UserHomeDirectory.path) } ?? "Log folder unavailable")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(logsDirectoryPath ?? "")
                    .accessibilityLabel(Text("Log folder \(logsDirectoryPath ?? "unavailable")"))
            }

            Spacer(minLength: NimbusSyncDesignTokens.spacing12)

            HStack(spacing: NimbusSyncDesignTokens.spacing8) {
                Picker("Log level", selection: Binding(
                    get: { ActivityLevel(rawValue: logLevel) ?? ActivityLogLevelPreference.defaultValue },
                    set: { level in
                        logLevel = level.rawValue
                        ActivityLog.shared.info("app", "Log level set to \(level.title)")
                    }
                )) {
                    ForEach(ActivityLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help("Lowest level NimbusSync and its Finder extension write to the log. Debug adds detailed sync diagnostics.")
                .accessibilityLabel(Text("Log level"))

                Button(action: copyLogs) {
                    Image(systemName: copiedLogs ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(SettingsIconButtonStyle())
                .help(copiedLogs ? "Copied" : "Copy these lines")
                .accessibilityLabel(Text(copiedLogs ? "Log lines copied" : "Copy log lines"))
                .disabled(recentLogLines.isEmpty)

                Button(action: onOpenLogs) {
                    Image(systemName: "folder")
                }
                .buttonStyle(SettingsIconButtonStyle())
                .help("Show in Finder")
                .accessibilityLabel(Text("Show log files in Finder"))
                .disabled(logsDirectoryPath == nil)
            }
        }
        .padding(NimbusSyncDesignTokens.spacing16)
    }

    private func copyLogs() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(recentLogLines.joined(separator: "\n"), forType: .string)
        copiedLogs = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedLogs = false }
    }

    // MARK: About page

    private var aboutPage: some View {
        SettingsPage(section: .about) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 14) {
                        AppIconView(size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 10) {
                                Text(AppIdentity.displayName)
                                    .font(.system(size: 20, weight: .semibold))
                                    .accessibilityAddTraits(.isHeader)
                                SettingsTagBadge(SettingsAboutText.version(
                                    short: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                                    build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String
                                ), tint: NimbusSyncDesignTokens.brandTextColor)
                            }
                            Text("Cloudreve for macOS")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Text("A native File Provider client for self-hosted Cloudreve instances. Your domains appear in the Finder sidebar, and files download only when you open them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(NimbusSyncDesignTokens.spacing16)
            }

            SettingsGroup("Resources") {
                SettingsRow(symbol: "checkmark.seal", tint: .green, title: "License") {
                    SettingsLinkButton(title: "Apache License 2.0") { openURL(SettingsLinks.license) }
                        .help(SettingsLinks.license.absoluteString)
                }
                SettingsRowDivider()
                SettingsRow(symbol: "chevron.left.forwardslash.chevron.right", tint: .gray, title: "Source code") {
                    SettingsLinkButton(title: "github.com/jorben/NimbusSync") { openURL(SettingsLinks.repository) }
                        .help(SettingsLinks.repository.absoluteString)
                }
            }
        }
    }

    // MARK: Domains page

    private var domainsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(section: .domains) {
                Button(action: onAddDomain) {
                    Label("Add Domain", systemImage: "plus")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("n", modifiers: .command)
                .help("Add a Cloudreve domain (⌘N)")
            } below: {
                if !domains.isEmpty {
                    SettingsDomainsSummaryLine(summary: SettingsDomainsSummary(domains: domains))
                        .padding(.top, NimbusSyncDesignTokens.spacing12)
                }
            }

            ScrollView {
                // Relative times such as "Last synced 2 min. ago" age while the window stays open.
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    VStack(alignment: .leading, spacing: 14) {
                        if finderIntegration == .off {
                            FinderIntegrationGuideCard(
                                onOpenSettings: onOpenFileProviderSettings,
                                onCheckAgain: onRefreshFinderIntegration
                            )
                        }
                        if domains.isEmpty {
                            SettingsDomainsEmptyState(onAddDomain: onAddDomain)
                        } else {
                            ForEach(domains, id: \.identifier) { domain in
                                domainCard(domain)
                            }
                        }
                    }
                    .frame(maxWidth: SettingsLayout.maxContentWidth, alignment: .leading)
                    .padding(.horizontal, SettingsLayout.pageInset)
                    .padding(.top, 4)
                    .padding(.bottom, SettingsLayout.pageInset)
                }
            }
        }
    }

    private func domainCard(_ domain: DomainDescriptor) -> some View {
        SettingsDomainCard(
            domain: domain,
            connection: connection(for: domain),
            progress: DomainCheckProgress.visible(for: domain, in: checkProgress),
            localPath: domainFolderPaths[domain.identifier],
            lastSyncedAt: lastSyncedAt[domain.identifier],
            isRemoving: removingDomainIdentifier == domain.identifier,
            actionsDisabled: removingDomainIdentifier != nil || renamingDomainIdentifier != nil,
            isRenaming: renamingDomainIdentifier == domain.identifier,
            onOpenFinder: { onOpenFinder(domain) },
            onOpenWeb: { onOpenWeb(domain) },
            onRename: domain.status.isLifecycleHold || renamingDomainIdentifier != nil ? nil : { onRename(domain, $0) }
        ) {
            Button { onOpenWeb(domain) } label: {
                Label("Open Cloudreve", systemImage: "safari")
            }
            Button { onReauthorize(domain) } label: {
                Label("Reauthorize", systemImage: "person.crop.circle.badge.checkmark")
            }
            Button { onCheckNow(domain) } label: {
                Label("Full check now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!checkableDomainIdentifiers.contains(domain.identifier))
            Button { editingExclusionsDomainIdentifier = domain.identifier } label: {
                Label("Edit Exclusions…", systemImage: "line.3.horizontal.decrease.circle")
            }
            Divider()
            Button(role: .destructive) { pendingRemoval = domain } label: {
                Label(domain.status == .preservedRemoval ? "Finish Removal…" : "Remove Domain…", systemImage: "trash")
            }
        }
    }

    private func connection(for domain: DomainDescriptor) -> ServerConnectionDisplay {
        connections[domain.identifier] ?? .notConnected
    }

    private func notificationBinding(_ keyPath: WritableKeyPath<NotificationPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { notificationPreferences[keyPath: keyPath] },
            set: { enabled in
                notificationPreferences[keyPath: keyPath] = enabled
                onNotificationsChanged(notificationPreferences)
            }
        )
    }
}

/// Lets the content run under a transparent title bar, so the sidebar's material reaches the top
/// edge and the traffic lights sit on it. The window keeps its title for Window menus,
/// accessibility and `focusWindow(titled:)`; it is only not drawn.
///
/// SwiftUI's Settings scene shows the title again on every update that touches the window (a
/// page switch, a refreshed snapshot), so the hidden title and transparent bar are held in place
/// by observing them. The reset happens inside the same change, before anything is drawn, so
/// the title never flashes. `toolbar(removing: .title)` would say this directly but needs macOS 15.
private struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowObserver() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowObserver: NSView {
        private var observations: [NSKeyValueObservation] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observations.removeAll()
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.toolbar = nil
            observations = [
                window.observe(\.titleVisibility) { window, _ in
                    if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
                },
                window.observe(\.titlebarAppearsTransparent) { window, _ in
                    if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
                },
            ]
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selectedSection: SettingsSection
    let domainCount: Int
    let finderIntegration: FinderIntegrationState
    let onOpenFileProviderSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppIconView(size: 36)
                Text(AppIdentity.displayName)
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .padding(.top, SettingsLayout.titlebarInset)
            .padding(.bottom, 20)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases) { section in
                    SettingsSidebarItem(
                        section: section,
                        isSelected: selectedSection == section,
                        badge: section == .domains && domainCount > 0 ? domainCount : nil
                    ) {
                        selectedSection = section
                    }
                    .keyboardShortcut(section.shortcut, modifiers: .command)
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: NimbusSyncDesignTokens.spacing16)

            Divider()
                .padding(.horizontal, 18)
            FinderIntegrationFooter(state: finderIntegration, onOpenSettings: onOpenFileProviderSettings)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SettingsSidebarBackground())
    }
}

private struct SettingsSidebarItem: View {
    let section: SettingsSection
    let isSelected: Bool
    let badge: Int?
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(isSelected ? NimbusSyncDesignTokens.brandColor : Color.primary.opacity(0.75))
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(section.title)
                    .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 4)
                if let badge {
                    SidebarCountBadge(count: badge)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(badge.map { "\(section.title), \($0)" } ?? section.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help("\(section.title) (⌘\(String(section.shortcut.character)))")
    }

    private var background: Color {
        if isSelected { return NimbusSyncDesignTokens.settingsSidebarSelection.opacity(colorScheme == .dark ? 0.26 : 0.2) }
        return isHovered ? Color.primary.opacity(0.05) : .clear
    }
}

/// A page's large title and one-line description, with an optional action on the right and
/// optional content underneath. Every Settings page uses it, so they share one rhythm.
private struct SettingsPageHeader<Trailing: View, Below: View>: View {
    let section: SettingsSection
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let below: () -> Below

    init(section: SettingsSection, @ViewBuilder trailing: @escaping () -> Trailing, @ViewBuilder below: @escaping () -> Below) {
        self.section = section
        self.trailing = trailing
        self.below = below
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: NimbusSyncDesignTokens.spacing16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title)
                        .font(.system(size: 28, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(section.subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: NimbusSyncDesignTokens.spacing16)
                trailing()
            }
            below()
        }
        .frame(maxWidth: SettingsLayout.maxContentWidth, alignment: .leading)
        .padding(.horizontal, SettingsLayout.pageInset)
        .padding(.top, SettingsLayout.pageTopInset)
        .padding(.bottom, NimbusSyncDesignTokens.spacing16)
    }
}

extension SettingsPageHeader where Trailing == EmptyView, Below == EmptyView {
    init(section: SettingsSection) {
        self.init(section: section, trailing: { EmptyView() }, below: { EmptyView() })
    }
}

private struct SettingsPage<Content: View>: View {
    let section: SettingsSection
    @ViewBuilder let content: () -> Content

    init(section: SettingsSection, @ViewBuilder content: @escaping () -> Content) {
        self.section = section
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(section: section)

            SettingsPageBody(maxContentWidth: SettingsLayout.maxContentWidth, horizontalInset: SettingsLayout.pageInset, content: content)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
