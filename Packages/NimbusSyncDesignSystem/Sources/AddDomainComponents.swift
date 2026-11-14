import SwiftUI
import AppKit
import CloudreveDomainKit

// The Add Domain window: three steps — the server's address, signing in with the browser, and
// confirming how the Domain appears in Finder — in the Settings window's card language.

// MARK: - Model

/// Where adding a Domain is while the app talks to the server and the browser.
public enum AddDomainAuthorizationPhase: Equatable, Sendable {
    /// Confirming the address answers as a supported Cloudreve server.
    case checkingServer
    /// The sign-in page is open in the browser; the app waits for its callback.
    case waitingForBrowser
    /// The browser came back; tokens and the account are being fetched.
    case finishingSignIn
}

public enum AddDomainStep: Int, CaseIterable, Identifiable, Sendable {
    case server
    case signIn
    case review

    public var id: Self { self }

    public var title: String {
        switch self {
        case .server: L10n.tr("Server")
        case .signIn: L10n.tr("Sign in")
        case .review: L10n.tr("Add to Finder")
        }
    }
}

/// What the last step shows about the Domain that is about to be added.
public struct AddDomainReview: Equatable, Sendable {
    public let origin: String
    public let serverVersion: String?
    public let remotePath: String

    public init(origin: String, serverVersion: String?, remotePath: String) {
        self.origin = origin
        self.serverVersion = serverVersion
        self.remotePath = remotePath
    }
}

public enum AddDomainText {
    public static var windowTitle: String { L10n.tr("Add Domain") }

    /// The typed address ready to check: trimmed, with "https://" added when no scheme was typed.
    public static func submittableOrigin(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("://") else { return trimmed }
        return "https://" + trimmed
    }

    /// Plain words for the failures adding a Domain usually meets, or nil to use the generic text.
    public static func message(for code: CoreErrorCode) -> String? {
        switch code {
        case .unsupportedServer:
            L10n.tr("NimbusSync couldn't find a Cloudreve 4.12 or later server at this address. Check the address, and that the server uses HTTPS.")
        case .network:
            L10n.tr("NimbusSync couldn't reach the server. Check the address and your internet connection.")
        case .authentication:
            L10n.tr("Sign-in didn't finish. Try again, and allow NimbusSync access when your browser asks.")
        case .permissionDenied:
            L10n.tr("Your account doesn't have access to this folder on the server.")
        default:
            nil
        }
    }

    public static func message(forURLError code: URLError.Code) -> String? {
        switch code {
        case .notConnectedToInternet:
            L10n.tr("Your Mac is offline. Connect to the internet and try again.")
        case .cannotFindHost, .dnsLookupFailed:
            L10n.tr("NimbusSync couldn't find this server. Check the address.")
        case .cannotConnectToHost, .timedOut, .networkConnectionLost:
            L10n.tr("The server didn't respond. Check the address, or try again later.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            L10n.tr("NimbusSync couldn't connect securely. The server's HTTPS certificate may not be valid.")
        default:
            nil
        }
    }
}

// MARK: - Window content

/// The whole Add Domain window. The step follows from what the app knows: a review when sign-in
/// finished, signing in while authorization runs, otherwise the address.
public struct AddDomainView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @Binding public var origin: String
    @Binding public var displayName: String
    public let authorizationPhase: AddDomainAuthorizationPhase?
    public let review: AddDomainReview?
    public let isAdding: Bool
    public let errorMessage: String?
    public let onContinue: (String) -> Void
    public let onCancelSignIn: () -> Void
    public let onBack: () -> Void
    public let onAdd: () -> Void
    public let onClose: () -> Void
    public let onOpenFileProviderSettings: () -> Void

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case origin
        case name
    }

    public init(
        origin: Binding<String>,
        displayName: Binding<String>,
        authorizationPhase: AddDomainAuthorizationPhase?,
        review: AddDomainReview?,
        isAdding: Bool,
        errorMessage: String?,
        onContinue: @escaping (String) -> Void,
        onCancelSignIn: @escaping () -> Void,
        onBack: @escaping () -> Void,
        onAdd: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onOpenFileProviderSettings: @escaping () -> Void
    ) {
        _origin = origin
        _displayName = displayName
        self.authorizationPhase = authorizationPhase
        self.review = review
        self.isAdding = isAdding
        self.errorMessage = errorMessage
        self.onContinue = onContinue
        self.onCancelSignIn = onCancelSignIn
        self.onBack = onBack
        self.onAdd = onAdd
        self.onClose = onClose
        self.onOpenFileProviderSettings = onOpenFileProviderSettings
    }

    public var step: AddDomainStep {
        if review != nil { return .review }
        if authorizationPhase != nil { return .signIn }
        return .server
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 36)
                .padding(.bottom, 20)

            Group {
                switch step {
                case .server: serverStep
                case .signIn: signInStep
                case .review: reviewStep
                }
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            footer
        }
        .frame(minWidth: 520, minHeight: 470)
        .tint(NimbusSyncDesignTokens.brandColor)
        .onAppear(perform: focusCurrentField)
        .onChange(of: step) { _ in focusCurrentField() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow, window.title == AddDomainText.windowTitle else { return }
            focusCurrentField()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                DomainLogoTile(size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add a Cloudreve domain")
                        .font(.system(size: 20, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            AddDomainStepper(current: step)
        }
    }

    private var subtitle: String {
        switch step {
        case .server: L10n.tr("Its files will appear in your Finder sidebar.")
        case .signIn: L10n.tr("NimbusSync never sees your password.")
        case .review: L10n.tr("Signed in. Check how it will appear on your Mac.")
        }
    }

    // MARK: Steps

    private var serverStep: some View {
        VStack(alignment: .leading, spacing: NimbusSyncDesignTokens.spacing12) {
            SettingsGroup("Server address") {
                HStack(spacing: NimbusSyncDesignTokens.spacing12) {
                    SettingsIconTile(symbol: "globe")
                    TextField("Server address", text: $origin, prompt: Text("cloud.example.com"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .origin)
                        .onSubmit(submitOrigin)
                        .accessibilityHint(Text(errorMessage ?? L10n.tr("The address of your Cloudreve server")))
                }
                .padding(.horizontal, NimbusSyncDesignTokens.spacing16)
                .padding(.vertical, NimbusSyncDesignTokens.spacing12)
                .overlay(
                    RoundedRectangle(cornerRadius: NimbusSyncDesignTokens.settingsCardRadius, style: .continuous)
                        .strokeBorder(errorMessage == nil ? Color.clear : NimbusSyncDesignTokens.errorTextColor.opacity(0.7), lineWidth: 1.5)
                )
            } footer: {
                if let errorMessage {
                    AddDomainErrorMessage(errorMessage)
                } else {
                    Text("Cloudreve 4.12 or later, over HTTPS. Next, you'll sign in with your browser.")
                }
            }
        }
    }

    private var signInStep: some View {
        let host = SettingsDomainText.host(of: AddDomainText.submittableOrigin(origin))
        return SettingsCard {
            VStack(spacing: NimbusSyncDesignTokens.spacing12) {
                ZStack {
                    SettingsIconTile(symbol: authorizationPhase == .waitingForBrowser ? "safari" : "server.rack", size: 56)
                }
                .padding(.bottom, NimbusSyncDesignTokens.spacing4)
                HStack(spacing: NimbusSyncDesignTokens.spacing8) {
                    ProgressView().controlSize(.small)
                    Text(signInTitle(host: host))
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(signInDetail(host: host))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, NimbusSyncDesignTokens.spacing20)
            .accessibilityElement(children: .combine)
        }
    }

    private func signInTitle(host: String) -> String {
        switch authorizationPhase {
        case .checkingServer, nil: L10n.tr("Checking \(host)…")
        case .waitingForBrowser: L10n.tr("Continue in your browser")
        case .finishingSignIn: L10n.tr("Finishing sign-in…")
        }
    }

    private func signInDetail(host: String) -> String {
        switch authorizationPhase {
        case .checkingServer, nil: L10n.tr("Making sure it's a Cloudreve server NimbusSync can sync with.")
        case .waitingForBrowser: L10n.tr("Sign in to \(host) in the page that opened, and allow NimbusSync access. This window moves on by itself when you're done.")
        case .finishingSignIn: L10n.tr("Getting your account details from \(host).")
        }
    }

    @ViewBuilder
    private var reviewStep: some View {
        if let review {
            VStack(alignment: .leading, spacing: NimbusSyncDesignTokens.spacing12) {
                SettingsCard {
                    SettingsRow(symbol: "character.cursor.ibeam", title: "Name in Finder") {
                        TextField("Name in Finder", text: $displayName, prompt: Text("Domain name"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .labelsHidden()
                            .focused($focusedField, equals: .name)
                            .onSubmit(submitReview)
                            .disabled(isAdding)
                    }
                    SettingsRowDivider()
                    SettingsRow(symbol: "server.rack", tint: .indigo, title: "Server") {
                        HStack(spacing: NimbusSyncDesignTokens.spacing8) {
                            Text(SettingsDomainText.host(of: review.origin))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(review.origin)
                            if let version = review.serverVersion {
                                SettingsTagBadge("v\(version)")
                            }
                        }
                    }
                    SettingsRowDivider()
                    SettingsRow(symbol: "folder", tint: .teal, title: "Remote folder") {
                        Text(review.remotePath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(review.remotePath)
                    }
                    SettingsRowDivider()
                    SettingsRow(symbol: "macwindow", tint: .gray, title: "On this Mac") {
                        Text("Finder › Locations › \(trimmedName.isEmpty ? "…" : trimmedName)")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if let errorMessage {
                    VStack(alignment: .leading, spacing: NimbusSyncDesignTokens.spacing4) {
                        AddDomainErrorMessage(errorMessage)
                        Button("Open File Provider Settings", action: onOpenFileProviderSettings)
                            .buttonStyle(.link)
                            .font(.callout)
                            .padding(.leading, 22)
                    }
                    .padding(.horizontal, 2)
                } else {
                    Text("macOS keeps the local copy and downloads files when you open them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: NimbusSyncDesignTokens.spacing8) {
                switch step {
                case .server:
                    Spacer()
                    Button("Cancel", action: onClose)
                        .keyboardShortcut(.cancelAction)
                    Button(action: submitOrigin) {
                        Text("Continue").frame(minWidth: 72)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(AddDomainText.submittableOrigin(origin).isEmpty)
                case .signIn:
                    Spacer()
                    Button("Cancel", action: onCancelSignIn)
                        .keyboardShortcut(.cancelAction)
                case .review:
                    Button("Back", action: onBack)
                        .keyboardShortcut(.cancelAction)
                        .disabled(isAdding)
                    Spacer()
                    Button(action: submitReview) {
                        HStack(spacing: 6) {
                            if isAdding {
                                ProgressView().controlSize(.small)
                            }
                            Text(isAdding ? L10n.tr("Adding…") : L10n.tr("Add to Finder"))
                        }
                        .frame(minWidth: 96)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || isAdding)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
        .background(Color.primary.opacity(0.03))
    }

    // MARK: Actions

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitOrigin() {
        let value = AddDomainText.submittableOrigin(origin)
        guard step == .server, !value.isEmpty else { return }
        onContinue(value)
    }

    private func submitReview() {
        guard step == .review, !trimmedName.isEmpty, !isAdding else { return }
        onAdd()
    }

    private func focusCurrentField() {
        let target: Field? = switch step {
        case .server: .origin
        case .review: .name
        case .signIn: nil
        }
        focusedField = nil
        guard let target else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
            focusedField = target
        }
    }
}

// MARK: - Pieces

/// Three numbered steps joined by lines; finished steps show a check.
public struct AddDomainStepper: View {
    @ObservedObject private var localization = AppLocalization.shared
    public let current: AddDomainStep
    @Environment(\.colorScheme) private var colorScheme

    public init(current: AddDomainStep) {
        self.current = current
    }

    public var body: some View {
        HStack(spacing: NimbusSyncDesignTokens.spacing8) {
            ForEach(AddDomainStep.allCases) { step in
                if step != .server {
                    Capsule()
                        .fill(step.rawValue <= current.rawValue ? NimbusSyncDesignTokens.brandColor.opacity(0.6) : Color.primary.opacity(0.12))
                        .frame(height: 2)
                        .frame(minWidth: 16, maxWidth: .infinity)
                }
                item(step)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(current.rawValue + 1) of \(AddDomainStep.allCases.count): \(current.title)"))
    }

    private func item(_ step: AddDomainStep) -> some View {
        let done = step.rawValue < current.rawValue
        let active = step == current
        return HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(done || active ? NimbusSyncDesignTokens.brandColor : Color.clear)
                Circle()
                    .strokeBorder(done || active ? Color.clear : Color.primary.opacity(0.25), lineWidth: 1)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(step.rawValue + 1)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(active ? Color.white : Color.secondary)
                }
            }
            .frame(width: 20, height: 20)
            Text(step.title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.primary : Color.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// A failure in red with its icon, placed right under what it is about.
public struct AddDomainErrorMessage: View {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .accessibilityHidden(true)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(.callout)
        .foregroundStyle(NimbusSyncDesignTokens.errorTextColor)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Error: \(message)"))
    }
}
