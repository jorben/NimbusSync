import AppKit
import FileProviderUI

final class ActionViewController: FPUIActionExtensionViewController {
    override func prepare(forAction actionIdentifier: String, itemIdentifiers: [NSFileProviderItemIdentifier]) {
	let itemIdentifier = itemIdentifiers.first?.rawValue ?? ""
	let isOpaqueItemIdentifier = itemIdentifier.hasPrefix("cri-") && UUID(uuidString: String(itemIdentifier.dropFirst(4))) != nil
		guard itemIdentifiers.count == 1,
			["io.github.jorben.nimbussync.open-in-nimbussync", "io.github.jorben.nimbussync.resolve-conflict"].contains(actionIdentifier),
			isOpaqueItemIdentifier else {
			extensionContext.cancelRequest(withError: NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.noSuchItem.rawValue))
			return
		}
		let label = NSTextField(labelWithString: "NimbusSync is opening this item.")
        label.alignment = .center
        label.frame = NSRect(x: 20, y: 20, width: 300, height: 40)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 80))
        view.addSubview(label)
        self.view = view
		let destination = actionIdentifier == "io.github.jorben.nimbussync.resolve-conflict" ? "conflict-item" : "item"
		// Dev builds register their own deep-link scheme so they never open the Release app.
		let scheme = (Bundle.main.object(forInfoDictionaryKey: "NimbusSyncURLScheme") as? String).flatMap { $0.isEmpty || $0.contains("$(") ? nil : $0 } ?? "nimbussync"
		let url = URL(string: "\(scheme)://\(destination)/\(itemIdentifier)")!
		extensionContext.open(url) { [weak self] _ in self?.extensionContext.completeRequest() }
    }

    override func prepare(forError error: Error) {
        extensionContext.cancelRequest(withError: error as NSError)
    }
}
