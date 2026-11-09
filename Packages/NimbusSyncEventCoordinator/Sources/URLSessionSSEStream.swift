import Foundation
import OSLog
import CloudreveAuthKit
import CloudreveDomainKit
import CloudreveObservability

/// URLSession-backed SSE stream. The Authorization header is attached only to
/// the configured Cloudreve origin; signed storage URLs are never used here.
public final class URLSessionSSEStream: EventStream, @unchecked Sendable {
    private let state: SSEStreamState

    public init(origin: URL, uri: String, clientID: String, vault: CredentialVault, credentialReference: String) {
        self.state = SSEStreamState(origin: origin, uri: uri, clientID: clientID, vault: vault, credentialReference: credentialReference)
    }

    public func next() async throws -> SSEEvent? {
        try await state.next()
    }

    public func cancel() async { await state.cancel() }
}

public final class CloudreveEventStreamFactory: EventStreamFactory, @unchecked Sendable {
    private let origin: URL
    private let uriState: EventURIState
    private let clientID: String
    private let vault: CredentialVault
    private let credentialReference: String

    public init(origin: URL, uri: String, clientID: String, vault: CredentialVault, credentialReference: String) {
        self.origin = origin; self.uriState = EventURIState(uri: uri); self.clientID = clientID; self.vault = vault; self.credentialReference = credentialReference
    }

    public func update(uri: String) async {
        await uriState.update(uri: uri)
    }

    public func open() async throws -> EventStream {
        let currentURI = await uriState.value()
        return URLSessionSSEStream(origin: origin, uri: currentURI, clientID: clientID, vault: vault, credentialReference: credentialReference)
    }
}

private actor EventURIState {
    private var uri: String
    init(uri: String) { self.uri = uri }
    func update(uri: String) { self.uri = uri }
    func value() -> String { uri }
}

private actor SSEStreamState {
    private let origin: URL
    private let uri: String
    private let clientID: String
    private let vault: CredentialVault
    private let credentialReference: String
    private let session: URLSession
    private let credentialRefresh: CredentialRefreshService
    private let channel = AsyncStreamChannel()
    private let logger = Logger(subsystem: "ai.tiy.nimbussync", category: "remote-events")
    private var started = false
    private var task: Task<Void, Never>?
    static let idleTimeout: TimeInterval = 90

    init(origin: URL, uri: String, clientID: String, vault: CredentialVault, credentialReference: String) {
        self.origin = origin; self.uri = uri; self.clientID = clientID; self.vault = vault; self.credentialReference = credentialReference
        let configuration = URLSessionConfiguration.ephemeral
        // An event stream is open-ended. timeoutIntervalForResource caps the
        // *whole* response, so the former 60 s made the client cancel every
        // stream after one minute (both proxies logged `context canceled` at
        // exactly those instants) and each reconnect forced a full reconcile.
        // The request timeout stays as an idle bound so a silently dead
        // connection is still detected.
        configuration.timeoutIntervalForRequest = Self.idleTimeout
        configuration.timeoutIntervalForResource = 7 * 24 * 3_600
        self.session = URLSession(configuration: configuration, delegate: SameOriginRedirectPolicy(), delegateQueue: nil)
        self.credentialRefresh = CredentialRefreshService(vault: vault)
    }

    func next() async throws -> SSEEvent? {
        if !started { started = true; start() }
        return try await channel.next()
    }

    func cancel() async {
        task?.cancel()
        task = nil
        await channel.finish()
    }

    private func start() {
        let channel = self.channel
        task = Task {
                let startedAt = Date()
                do {
                    var credential = try await credentialRefresh.credential(origin: origin, reference: credentialReference)
                    var components = URLComponents(url: origin.appendingPathComponent("api/v4/file/events"), resolvingAgainstBaseURL: false)
                    components?.setCloudreveQueryItems([URLQueryItem(name: "uri", value: uri)])
                    guard let url = components?.url else { throw CoreFailure(code: .network, retryable: false) }
                    var request = URLRequest(url: url, timeoutInterval: Self.idleTimeout)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue(clientID, forHTTPHeaderField: "X-Cr-Client-Id")
                    request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
                    logger.info("sse.connect.begin endpoint=file/events")
                    var (bytes, response) = try await session.bytes(for: request)
                    if (response as? HTTPURLResponse)?.statusCode == 401 {
                        credential = try await credentialRefresh.credential(origin: origin, reference: credentialReference, forceRefresh: true)
                        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
                        (bytes, response) = try await session.bytes(for: request)
                    }
                    guard let http = response as? HTTPURLResponse else { throw CoreFailure(code: .network, retryable: true) }
                    logger.info("sse.connect.response endpoint=file/events status=\(http.statusCode, privacy: .public)")
                    if http.statusCode == 200 { ActivityLog.shared.info("live-updates", "Live updates connected") }
                    guard http.statusCode == 200, http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true else { throw CoreFailure(code: .network, retryable: true) }
                    // Raw bytes, not `bytes.lines`: that drops the empty lines that end each event.
                    var feeder = SSEByteFeeder()
                    for try await byte in bytes {
                        for event in try feeder.append(byte) { await channel.yield(event) }
                    }
                    for event in try feeder.finish() { await channel.yield(event) }
                    logger.info("sse.stream.ended endpoint=file/events lifetime_s=\(Int(Date().timeIntervalSince(startedAt)), privacy: .public)")
                    ActivityLog.shared.info("live-updates", "Live updates ended after \(Int(Date().timeIntervalSince(startedAt)))s")
                    await channel.finish()
                } catch {
                    let reason: String
                    if let urlError = error as? URLError { reason = "url:\(urlError.code.rawValue)" }
                    else if let failure = error as? CoreFailure { reason = "core:\(failure.code.rawValue)" }
                    else if error is CancellationError { reason = "cancelled" }
                    else { reason = String(describing: type(of: error)) }
                    logger.error("sse.stream.failed endpoint=file/events reason=\(reason, privacy: .public) lifetime_s=\(Int(Date().timeIntervalSince(startedAt)), privacy: .public)")
                    let lifetime = Int(Date().timeIntervalSince(startedAt))
                    if (error as? URLError)?.code == .cancelled || error is CancellationError {
                        // NimbusSync closed the stream itself (a restart, a removed Domain, quitting).
                        ActivityLog.shared.info("live-updates", "Live updates stopped · reason=\(reason) after \(lifetime)s")
                    } else {
                        ActivityLog.shared.warning("live-updates", "Live updates disconnected · reason=\(reason) after \(lifetime)s")
                    }
                    await channel.finish(error)
                }
        }
    }
}

private final class SameOriginRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var request = request
        let current = task.currentRequest?.url
        let next = request.url
        if current?.scheme != next?.scheme || current?.host != next?.host || current?.port != next?.port { request.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(request)
    }
}

private actor AsyncStreamChannel {
    private var values: [SSEEvent] = []
    private var waiter: CheckedContinuation<SSEEvent?, Error>?
    private var finished = false
    private var failure: Error?

    func yield(_ value: SSEEvent) {
        if let waiter { self.waiter = nil; waiter.resume(returning: value) } else { values.append(value) }
    }
    func finish(_ error: Error? = nil) {
        finished = true; failure = error
        if let waiter { self.waiter = nil; if let error { waiter.resume(throwing: error) } else { waiter.resume(returning: nil) } }
    }
    func next() async throws -> SSEEvent? {
        if !values.isEmpty { return values.removeFirst() }
        if let failure { throw failure }
        if finished { return nil }
        return try await withCheckedThrowingContinuation { continuation in waiter = continuation }
    }
}
