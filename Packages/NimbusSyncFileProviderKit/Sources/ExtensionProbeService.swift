import Foundation
import FileProvider
import CloudreveDomainKit

/// Serves `NimbusSyncExtensionProbing` so the app can confirm this extension starts and
/// answers (see `ExtensionReachability`). Restricted: only the app that manages the Domain
/// may connect.
final class ExtensionProbeServiceSource: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NSXPCListener?
    private let responder = ExtensionProbeResponder()

    var serviceName: NSFileProviderServiceName { ExtensionProbeService.name }

    var isRestricted: Bool { true }

    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint {
        lock.lock()
        defer { lock.unlock() }
        // One anonymous listener serves every probe for the life of the process.
        if let listener { return listener.endpoint }
        let listener = NSXPCListener.anonymous()
        listener.delegate = self
        listener.resume()
        self.listener = listener
        return listener.endpoint
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = ExtensionProbeService.makeInterface()
        newConnection.exportedObject = responder
        newConnection.resume()
        return true
    }

    func invalidate() {
        lock.lock()
        let listener = self.listener
        self.listener = nil
        lock.unlock()
        listener?.invalidate()
    }
}

private final class ExtensionProbeResponder: NSObject, NimbusSyncExtensionProbing, @unchecked Sendable {
    func probe(reply: @escaping @Sendable (String, String) -> Void) {
        reply(Bundle.main.bundlePath, AppIdentity.version ?? "")
    }
}
