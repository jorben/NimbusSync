import SwiftUI
import Combine
import AppKit
import CloudreveDomainKit

/// Translate the presentation of persisted conflict codes without changing their stored values.
public enum ProductConflictText {
    public static func kind(_ code: String) -> String {
        switch code {
        case "version_conflict": L10n.tr("Changed on both sides")
        case "name_collision": L10n.tr("Name already in use")
        default: code
        }
    }

    public static func summary(_ value: String) -> String {
        if value == "metadata" { return L10n.tr("Metadata changed") }
        if value == "remote_version_unknown" { return L10n.tr("Remote version unknown") }
        if value.hasPrefix("version:") { return L10n.tr("Version \(String(value.dropFirst(8)))") }
        if value.hasPrefix("bytes:"), let size = Int64(value.dropFirst(6)) {
            return CloudreveLocalization.format(bytes: size)
        }
        return value
    }
}

public struct ConflictCenterView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @Binding public var conflicts: [ProductConflict]
    public let onKeepRemote: (ProductConflict) -> Void
    public let onOverwriteRemote: (ProductConflict) -> Void
    public let onKeepBoth: (ProductConflict) -> Void
    public let onExportLocalCopy: (ProductConflict) -> Void
    public let selectedItemIdentifier: String?
    @State private var selectedID: UUID?
    public init(conflicts: Binding<[ProductConflict]>, selectedItemIdentifier: String? = nil, onKeepRemote: @escaping (ProductConflict) -> Void, onOverwriteRemote: @escaping (ProductConflict) -> Void, onKeepBoth: @escaping (ProductConflict) -> Void, onExportLocalCopy: @escaping (ProductConflict) -> Void = { _ in }) { _conflicts = conflicts; self.selectedItemIdentifier = selectedItemIdentifier; self.onKeepRemote = onKeepRemote; self.onOverwriteRemote = onOverwriteRemote; self.onKeepBoth = onKeepBoth; self.onExportLocalCopy = onExportLocalCopy; _selectedID = State(initialValue: conflicts.wrappedValue.first(where: { $0.itemIdentifier == selectedItemIdentifier })?.id) }
    public var body: some View {
        NavigationSplitView {
            List(conflicts.filter { $0.state == "pending" }, selection: $selectedID) { conflict in
                VStack(alignment: .leading) { Text(conflict.filename); Text(ProductConflictText.kind(conflict.kind)).font(.caption).foregroundStyle(.secondary) }
                    .tag(conflict.id)
            }
            .navigationTitle("Conflicts")
        } detail: {
            if let first = conflicts.first(where: { $0.id == selectedID }) ?? conflicts.first(where: { $0.state == "pending" }) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(first.filename).font(.title2)
                    Text("Base: \(ProductConflictText.summary(first.baseSummary))").font(.caption).foregroundStyle(.secondary)
                    Text("Local: \(ProductConflictText.summary(first.localSummary))")
                    Text("Remote: \(ProductConflictText.summary(first.remoteSummary))")
                    HStack {
                        Button("Keep Remote") { onKeepRemote(first) }.buttonStyle(.bordered)
                        Button("Overwrite Remote") { onOverwriteRemote(first) }.buttonStyle(.bordered).disabled(!first.sourceAvailable)
                        Button("Keep Both") { onKeepBoth(first) }.buttonStyle(.borderedProminent).disabled(!first.sourceAvailable)
                    }
                    if first.localSourceKind != "user_export" {
                        Button("Export Local Copy") { onExportLocalCopy(first) }.buttonStyle(.bordered)
                    }
                    Spacer()
                }.padding(24)
            } else { Text("No conflicts need attention.").foregroundStyle(.secondary) }
        }
        .frame(minWidth: 640, minHeight: 460)
        .onReceive(Just(selectedItemIdentifier)) { itemIdentifier in
            selectedID = conflicts.first(where: { $0.itemIdentifier == itemIdentifier })?.id
        }
    }
}

public struct ExclusionRulesView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @State private var text: String
    public let onApply: (String) -> Void
    public init(initialText: String = "", onApply: @escaping (String) -> Void) { _text = State(initialValue: initialText); self.onApply = onApply }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exclude from this Mac").font(.title3)
            Text("One pattern per line. Remote files remain on Cloudreve.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minHeight: 180).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack { Spacer(); Button("Apply") { onApply(text) }.buttonStyle(.borderedProminent) }
        }.padding(20)
    }
}
