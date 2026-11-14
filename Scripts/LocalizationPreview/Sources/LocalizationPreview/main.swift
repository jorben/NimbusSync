import AppKit
import SwiftUI
import CloudreveDomainKit
import CloudreveDesignSystem
import CloudreveProductKit

// Read-only runtime fixtures. This executable has no auth, Store, network or File Provider
// runtime and runs under its own app identity/preferences, separate from installed editions.
private let commandName = Notification.Name("io.github.jorben.nimbussync.localization-preview.command")

private struct LocalizedRoot: View {
    @ObservedObject private var localization = AppLocalization.shared
    let content: () -> AnyView
    var body: some View {
        content()
            .environment(\.locale, localization.locale)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
private final class PreviewController: NSObject, NSApplicationDelegate {
    private let output: URL
    private var windows: [String: NSWindow] = [:]
    private var panel: MenuBarPanelController?
    private var events: [[String: Any]] = []
    private var domains: [DomainDescriptor] = []
    private let now = Date()

    init(output: URL) { self.output = output }

    func applicationDidFinishLaunching(_ notification: Notification) {
        precondition(AppIdentity.baseIdentifier == "io.github.jorben.nimbussync.localization-preview", "Package this preview with its isolated Info.plist before running")
        AppLanguagePreference.sharedDefaults().removePersistentDomain(forName: AppIdentity.appGroupIdentifier)
        AppLocalization.shared.select(.english)
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scope = try! RemoteScope(origin: "https://cloud.example.invalid", accountID: "qa-account", rootURI: "cloudreve://my/")
        domains = [DomainStatus.healthy, .reconciling, .authExpired].enumerated().map { index, status in
            var domain = DomainDescriptor(displayName: ["QA Photos", "QA Archive", "QA Documents"][index], scope: scope, rootRemoteID: "qa-root-\(index)", accountID: "qa-account", secretReference: "fixture-reference")
            domain.status = status
            return domain
        }
        makeWindow("domains-wide", width: 820, height: 700) { [self] in AnyView(domainsPage()) }
        makeWindow("domains-narrow", width: 580, height: 700) { [self] in AnyView(domainsPage()) }
        makeWindow("authorization-checking", width: 580, height: 560) { [self] in AnyView(addDomain(phase: .checkingServer)) }
        makeWindow("authorization-browser", width: 580, height: 560) { [self] in AnyView(addDomain(phase: .waitingForBrowser)) }
        makeWindow("authorization-finishing", width: 580, height: 560) { [self] in AnyView(addDomain(phase: .finishingSignIn)) }
        makeWindow("authorization-review", width: 580, height: 560) { [self] in AnyView(addDomain(review: AddDomainReview(origin: "https://cloud.example.invalid", serverVersion: "4.12.0", remotePath: "/Photos"))) }
        let conflict = ProductConflict(id: UUID(), domainIdentifier: domains[0].identifier, itemIdentifier: CloudreveIdentifier.item(), filename: "QA Report 100% @.pdf", kind: "version_conflict", baseSummary: "version:base-v1", localSummary: "bytes:2048", remoteSummary: "remote_version_unknown", localSourceKind: "system_pending", sourceAvailable: true, createdAt: now)
        makeWindow("conflicts", width: 800, height: 550) {
            AnyView(ConflictCenterView(conflicts: .constant([conflict]), onKeepRemote: { _ in }, onOverwriteRemote: { _ in }, onKeepBoth: { _ in }, onExportLocalCopy: { _ in }))
        }
        makeWindow("finder-guide", width: 520, height: 640) {
            AnyView(FinderIntegrationGuideView(onOpenSettings: {}, onLater: {}))
        }
        let icon = MenuBarIconAnimator()
        icon.setState(.attention)
        panel = MenuBarPanelController(icon: icon) { [self] in
            LocalizedRoot { [self] in AnyView(MenuBarPopoverView(domains: domains, recentTasks: [TaskDisplay(id: UUID(), title: "QA Transfer.pdf", progress: nil, detail: "download_failed", state: "failed", date: now, domainName: "QA Photos")], hasActionableConflicts: true, onQuit: {})) }
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(handleCommand(_:)), name: commandName, object: nil)
        record("ready")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow(_ name: String, width: CGFloat, height: CGFloat, content: @escaping () -> AnyView) {
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: width, height: height), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = name
        window.identifier = NSUserInterfaceItemIdentifier(name)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LocalizedRoot(content: content))
        window.center()
        window.orderFront(nil)
        windows[name] = window
    }

    private func domainsPage() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.tr("Domains")).font(.largeTitle.bold())
                SettingsDomainsSummaryLine(summary: SettingsDomainsSummary(domains: domains))
                ForEach(Array(domains.enumerated()), id: \.element.identifier) { [self] index, domain in
                    SettingsDomainCard(domain: domain,
                        connection: ServerConnectionDisplay(kind: index == 2 ? .authorizationRequired : .connected, since: now.addingTimeInterval(-120)),
                        progress: index == 1 ? DomainCheckProgress(phase: .scanningFiles, scannedItems: 1_234, expectedItems: 5_600, startedAt: now.addingTimeInterval(-30)) : nil,
                        localPath: "~/Library/CloudStorage/QA-\(index)", lastSyncedAt: now.addingTimeInterval(-120), isRemoving: false, actionsDisabled: false,
                        onOpenFinder: {}, onOpenWeb: {}, onRename: { _ in }) {
                            Button(L10n.tr("Full check now")) {}
                            Button(L10n.tr("Reauthorize")) {}
                            Button(L10n.tr("Edit Exclusions…")) {}
                        }
                }
            }.padding(20)
        }
    }

    private func addDomain(phase: AddDomainAuthorizationPhase? = nil, review: AddDomainReview? = nil) -> some View {
        AddDomainView(origin: .constant("https://cloud.example.invalid"), displayName: .constant("QA Photos"), authorizationPhase: phase, review: review, isAdding: false, errorMessage: nil, onContinue: { _ in }, onCancelSignIn: {}, onBack: {}, onAdd: {}, onClose: {}, onOpenFileProviderSettings: {})
    }

    @objc private func handleCommand(_ notification: Notification) {
        guard let command = notification.object as? String else { return }
        switch command {
        case "en", "zh-Hans":
            let before = visiblePanel?.windowNumber
            AppLocalization.shared.select(command == "en" ? .english : .simplifiedChinese)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            let after = visiblePanel?.windowNumber
            record("language", details: ["panel_was_open": before != nil, "panel_still_open": panel?.isPanelShown == true, "same_panel_window": before != nil && before == after])
        case "live-sweep":
            for choice in [AppLanguageChoice.english, .simplifiedChinese, .english] {
                NSApp.activate(ignoringOtherApps: true)
                if panel?.isPanelShown != true { panel?.open() }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                let before = visiblePanel?.windowNumber
                AppLocalization.shared.select(choice)
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                let after = visiblePanel?.windowNumber
                record("live-panel-switch", details: ["panel_was_open": before != nil, "panel_still_open": panel?.isPanelShown == true, "same_panel_window": before != nil && before == after])
                if let window = visiblePanel { writeImage(window, name: "open-popover") }
            }
        case "snapshot": snapshot()
        case "panel-open":
            NSApp.activate(ignoringOtherApps: true)
            panel?.open()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            record("panel-open", details: ["panel_open": panel?.isPanelShown == true])
        case "panel-snapshot":
            guard let window = visiblePanel else { record("panel-missing"); return }
            writeImage(window, name: "open-popover")
            record("panel-snapshot", details: ["panel_window": window.windowNumber])
        case "quit": NSApp.terminate(nil)
        default: break
        }
    }

    private var visiblePanel: NSWindow? { NSApp.windows.first { $0 is NSPanel && $0.isVisible } }

    private func snapshot() {
        panel?.close()
        var frames: [[String: Any]] = []
        for name in windows.keys.sorted() {
            let window = windows[name]!
            window.makeKeyAndOrderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            writeImage(window, name: name)
            frames.append(["name": name, "window": window.windowNumber, "width": window.contentView!.bounds.width, "height": window.contentView!.bounds.height, "visible": window.isVisible])
        }
        record("snapshot", details: ["windows": frames])
    }

    private func writeImage(_ window: NSWindow, name: String) {
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try! data.write(to: output.appendingPathComponent("\(name).\(AppLocalization.shared.language.rawValue).png"))
        }
    }

    private func record(_ event: String, details: [String: Any] = [:]) {
        var value = details
        value["event"] = event
        value["language"] = AppLocalization.shared.language.rawValue
        events.append(value)
        try! JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("runtime-events.json"))
    }
}

let app = NSApplication.shared
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/nimbussync-localization-preview-evidence")
private let controller = PreviewController(output: output)
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
