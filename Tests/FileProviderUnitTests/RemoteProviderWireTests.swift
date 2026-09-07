import XCTest
import Foundation
import FileProvider
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveAuthKit
import CloudreveFileProviderKit

final class RemoteProviderWireTests: XCTestCase {
    func testDirectoryPageNumberHydrationStopsAtReportedTotal() async throws {
        try await assertDirectoryHydration(mode: .page, expectedQueries: ["page=1", "page=2"])
    }

    func testDirectoryCursorHydrationDoesNotRestartPagePaginationAtEnd() async throws {
        try await assertDirectoryHydration(mode: .cursor, expectedQueries: ["page=1", "next_page_token=cursor-1"])
    }

    private func assertDirectoryHydration(mode: DirectoryPageWireURLProtocol.Mode, expectedQueries: [String]) async throws {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-page-wire-\(UUID().uuidString).sqlite3")
        defer {
            DirectoryPageWireURLProtocol.clear()
            try? FileManager.default.removeItem(at: storeURL)
            for suffix in ["-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
            }
        }
        let store = try SQLiteStateStore(url: storeURL)
        let vault = MemoryCredentialVault()
        let domainIdentifier = CloudreveIdentifier.domain()
        let rootURI = try CloudreveRemoteURI.canonical("/", accountID: "account")
        let capabilities = CapabilitySnapshot(
            completePagination: .verified,
            cursorPagination: .verified,
            snapshotSafePagination: .verified
        )
        let scope = try RemoteScope(origin: "https://cloudreve.example", accountID: "account", rootURI: rootURI)
        try store.registerDomain(DomainDescriptor(identifier: domainIdentifier, displayName: "Page Test", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential", capabilitySnapshot: capabilities))
        try vault.write(Credential(accessToken: "unit-token", refreshToken: "refresh-token", accessExpiry: Date().addingTimeInterval(3_600)), reference: "credential")
        let state = DirectoryPageWireURLProtocol.State(mode: mode)
        DirectoryPageWireURLProtocol.install(state)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DirectoryPageWireURLProtocol.self]
        var backend: NimbusSyncRemoteBackend? = NimbusSyncRemoteBackend(
            origin: URL(string: "https://cloudreve.example")!,
            rootURI: rootURI,
            store: store,
            vault: vault,
            credentialReference: "credential",
            capabilitySnapshot: capabilities,
            providerName: "unverified",
            secretVault: MemoryOpaqueSecretVault(),
            domainIdentifier: domainIdentifier,
            urlSessionConfiguration: configuration
        )
        let context = FileProviderOperationContext(itemIdentifier: .rootContainer, progress: Progress(totalUnitCount: 1), registrar: NoopURLSessionTaskRegistrar(), cancellation: CancellationToken())

        do {
            _ = try await backend!.childrenPage(parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, cursor: nil, context: context)
            XCTFail("the first remote page must remain private until the snapshot is complete")
        } catch let failure as CoreFailure {
            XCTAssertEqual(failure.code, .cannotSynchronize)
        }

        let page = try await backend!.childrenPage(parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, cursor: nil, context: context)
        backend = nil
        XCTAssertTrue(page.complete)
        XCTAssertEqual(page.items.map(\.remoteID), ["remote-page-1", "remote-page-2"])
        XCTAssertEqual(state.requestedQueries, expectedQueries)
    }

    func testQiniuAsyncUploadUsesOneBasedPartsAndUpTokenOnStorageOnly() async throws {
        let fixture = try UploadWireFixture(provider: "qiniu", chunkSize: 4)
        defer { fixture.cleanup() }
        let source = try fixture.makeSource(Data("0123456789".utf8))
        let protocolState = UploadWireURLProtocol.State(provider: "qiniu", sourceSize: 10)
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)
        let context = fixture.makeContext(itemIdentifier: fixture.template.itemIdentifier)

        let result = try await backend!.create(
            CreateRequest(template: fixture.template, contents: source, replayKey: "wire-qiniu"),
            context: context
        )
        backend = nil

        XCTAssertEqual(result.remoteID, "remote-wire-qiniu")
        let requests = protocolState.requests
        let partRequests = requests.filter { $0.url.path.hasPrefix("/qiniu/upload/") && $0.url.path != "/qiniu/upload/" }
        XCTAssertEqual(partRequests.map(\.url.path), ["/qiniu/upload/1", "/qiniu/upload/2", "/qiniu/upload/3"])
        XCTAssertEqual(partRequests.map(\.method), ["PUT", "PUT", "PUT"])
        XCTAssertTrue(partRequests.allSatisfy { $0.authorization == "UpToken qiniu-token" })
        XCTAssertTrue(partRequests.allSatisfy { $0.authorization?.hasPrefix("Bearer ") == false })
        XCTAssertEqual(partRequests.map(\.body), [Data("0123".utf8), Data("4567".utf8), Data("89".utf8)])

        let completion = try XCTUnwrap(requests.first { $0.url.path == "/qiniu/upload" && $0.method == "POST" })
        XCTAssertEqual(completion.authorization, "UpToken qiniu-token")
        XCTAssertTrue(completion.bodyString?.contains("\"partNumber\":1") == true)
        XCTAssertTrue(completion.bodyString?.contains("\"partNumber\":2") == true)
        XCTAssertTrue(completion.bodyString?.contains("\"partNumber\":3") == true)

        let cloudreveRequests = requests.filter { $0.url.path.hasPrefix("/api/v4/") }
        XCTAssertTrue(cloudreveRequests.allSatisfy { $0.authorization == "Bearer unit-token" })
    }

    func testUpyunAsyncUploadUsesSingleMultipartFileAndDoesNotCallCompletionEndpoint() async throws {
        let fixture = try UploadWireFixture(provider: "upyun", chunkSize: 4)
        defer { fixture.cleanup() }
        let sourceContents = Data("upyun-payload".utf8)
        let source = try fixture.makeSource(sourceContents)
        let protocolState = UploadWireURLProtocol.State(provider: "upyun", sourceSize: sourceContents.count)
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)
        let context = fixture.makeContext(itemIdentifier: fixture.template.itemIdentifier)

        let result = try await backend!.create(
            CreateRequest(template: fixture.template, contents: source, replayKey: "wire-upyun"),
            context: context
        )
        backend = nil

        XCTAssertEqual(result.remoteID, "remote-wire-upyun")
        let requests = protocolState.requests
        let upload = try XCTUnwrap(requests.first { $0.url.path == "/upyun/form" })
        XCTAssertEqual(upload.method, "POST")
        XCTAssertTrue(upload.contentType?.hasPrefix("multipart/form-data; boundary=") == true)
        XCTAssertNil(upload.authorization)
        XCTAssertTrue(upload.bodyString?.contains("name=\"policy\"") == true)
        XCTAssertTrue(upload.bodyString?.contains("upyun-policy") == true)
        XCTAssertTrue(upload.bodyString?.contains("name=\"authorization\"") == true)
        XCTAssertTrue(upload.bodyString?.contains("upyun-authorization") == true)
        XCTAssertTrue(upload.bodyString?.contains("name=\"content-type\"") == true)
        XCTAssertTrue(upload.bodyString?.contains("text/plain") == true)
        XCTAssertTrue(upload.body?.range(of: sourceContents) != nil)
        XCTAssertNil(requests.first { $0.url.path == "/upyun/complete" })
    }

    func testUpyunMultipartMimeValueFallsBackWhenItContainsControlCharacters() throws {
        let fixture = try UploadWireFixture(provider: "upyun", chunkSize: 4)
        defer { fixture.cleanup() }
        let source = try fixture.makeSource(Data("payload".utf8))
        let protocolState = UploadWireURLProtocol.State(provider: "upyun", sourceSize: 7, mimeType: "text/plain\r\nX-Injected: true")
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)

        _ = try backend!.create(template: fixture.template, content: Data("payload".utf8), replayKey: "wire-upyun-sync")
        backend = nil

        let upload = try XCTUnwrap(protocolState.requests.first { $0.url.path == "/upyun/form" })
        XCTAssertTrue(upload.bodyString?.contains("Content-Type: application/octet-stream") == true)
        XCTAssertFalse(upload.bodyString?.contains("X-Injected") == true)
        _ = source
    }

    func testCloudreveRemoteAsyncUploadUsesZeroBasedChunkQueryAndOpaqueCredential() async throws {
        let fixture = try UploadWireFixture(provider: "remote", chunkSize: 4)
        defer { fixture.cleanup() }
        let source = try fixture.makeSource(Data("0123456789".utf8))
        let protocolState = UploadWireURLProtocol.State(provider: "remote", sourceSize: 10)
        var backend: NimbusSyncRemoteBackend? = fixture.makeBackend(protocolState: protocolState)
        let context = fixture.makeContext(itemIdentifier: fixture.template.itemIdentifier)

        let result = try await backend!.create(
            CreateRequest(template: fixture.template, contents: source, replayKey: "wire-remote"),
            context: context
        )
        backend = nil

        XCTAssertEqual(result.remoteID, "remote-wire-remote")
        let remoteRequests = protocolState.requests.filter { $0.url.path == "/remote/upload" }
        XCTAssertEqual(remoteRequests.count, 3)
        XCTAssertEqual(remoteRequests.map { $0.url.query?.split(separator: "&").last.map(String.init) }, ["chunk=0", "chunk=1", "chunk=2"])
        XCTAssertEqual(remoteRequests.map(\.body), [Data("0123".utf8), Data("4567".utf8), Data("89".utf8)])
        XCTAssertTrue(remoteRequests.allSatisfy { $0.authorization == "remote-token" })
        XCTAssertTrue(remoteRequests.allSatisfy { $0.authorization?.hasPrefix("Bearer ") == false })
    }
}

private final class DirectoryPageWireURLProtocol: URLProtocol {
    enum Mode: Sendable {
        case page
        case cursor
    }

    final class State: @unchecked Sendable {
        let mode: Mode
        private let lock = NSLock()
        private var queries: [String] = []

        init(mode: Mode) {
            self.mode = mode
        }

        var requestedQueries: [String] {
            lock.lock()
            defer { lock.unlock() }
            return queries
        }

        func append(query: String) {
            lock.lock()
            queries.append(query)
            lock.unlock()
        }
    }

    private final class StateBox: @unchecked Sendable {
        let lock = NSLock()
        var value: State?
    }

    private static let stateBox = StateBox()

    static func install(_ state: State) {
        stateBox.lock.lock()
        stateBox.value = state
        stateBox.lock.unlock()
    }

    static func clear() {
        stateBox.lock.lock()
        stateBox.value = nil
        stateBox.lock.unlock()
    }

    private static func state() -> State? {
        stateBox.lock.lock()
        defer { stateBox.lock.unlock() }
        return stateBox.value
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "cloudreve.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let state = Self.state() else {
            client?.urlProtocol(self, didFailWithError: WireTestError.cannotCreateSource)
            return
        }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let cursor = queryItems.first(where: { $0.name == "next_page_token" })?.value
        let page = queryItems.first(where: { $0.name == "page" })?.value.flatMap(Int.init) ?? (cursor == nil ? 1 : 2)
        state.append(query: cursor.map { "next_page_token=\($0)" } ?? "page=\(page)")
        var pagination: [String: Any] = ["page": page, "page_size": 1, "total_items": 2]
        if state.mode == .cursor, cursor == nil {
            pagination["next_token"] = "cursor-1"
        }
        let body: [String: Any] = [
            "code": 0,
            "data": [
                "files": [[
                    "type": 0,
                    "id": "remote-page-\(page)",
                    "name": "page-\(page).txt",
                    "created_at": "2026-09-07T00:00:00Z",
                    "updated_at": "2026-09-07T00:00:00Z",
                    "size": page,
                    "path": "/page-\(page).txt",
                    "permission": "r",
                    "capability": "r",
                    "primary_entity": "entity-\(page)"
                ]],
                "pagination": pagination
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class UploadWireFixture {
    let provider: String
    let chunkSize: Int64
    let storeURL: URL
    let rootURI: String
    let domainIdentifier: String
    let template: RemoteItem
    let credentialVault: MemoryCredentialVault
    let secretVault: MemoryOpaqueSecretVault
    private var sourceURLs: [URL] = []

    init(provider: String, chunkSize: Int64) throws {
        self.provider = provider
        self.chunkSize = chunkSize
        self.storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-wire-\(provider)-\(UUID().uuidString).sqlite3")
        self.rootURI = try CloudreveRemoteURI.canonical("/", accountID: "account")
        self.domainIdentifier = CloudreveIdentifier.domain()
        self.template = RemoteItem(
            itemIdentifier: CloudreveIdentifier.item(),
            remoteID: nil,
            parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
            name: "payload.bin",
            uri: try CloudreveRemoteURI.append(rootURI, name: "payload.bin"),
            kind: .file,
            contentType: "public.data",
            size: 0,
            version: ItemVersion(content: Data("template".utf8), metadata: Data("template".utf8)),
            canRead: true,
            canWrite: true
        )
        self.credentialVault = MemoryCredentialVault()
        self.secretVault = MemoryOpaqueSecretVault()
        let store = try SQLiteStateStore(url: storeURL)
        let capabilities = Self.capabilities(provider: provider)
        let scope = try RemoteScope(origin: "https://cloudreve.example", accountID: "account", rootURI: rootURI)
        try store.registerDomain(DomainDescriptor(identifier: domainIdentifier, displayName: "Wire Test", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential", capabilitySnapshot: capabilities))
        try credentialVault.write(Credential(accessToken: "unit-token", refreshToken: "refresh-token", accessExpiry: Date().addingTimeInterval(3_600)), reference: "credential")
    }

    func makeSource(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-wire-source-\(UUID().uuidString).bin")
        guard FileManager.default.createFile(atPath: url.path, contents: data) else { throw WireTestError.cannotCreateSource }
        sourceURLs.append(url)
        return url
    }

    func makeBackend(protocolState: UploadWireURLProtocol.State) -> NimbusSyncRemoteBackend {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadWireURLProtocol.self]
        UploadWireURLProtocol.install(protocolState)
        let store = try! SQLiteStateStore(url: storeURL)
        return NimbusSyncRemoteBackend(
            origin: URL(string: "https://cloudreve.example")!,
            rootURI: rootURI,
            store: store,
            vault: credentialVault,
            credentialReference: "credential",
            capabilitySnapshot: Self.capabilities(provider: provider),
            providerName: provider,
            secretVault: secretVault,
            requestTimeout: 10,
            clientID: "wire-client",
            domainIdentifier: domainIdentifier,
            urlSessionConfiguration: configuration
        )
    }

    func makeContext(itemIdentifier: String) -> FileProviderOperationContext {
        FileProviderOperationContext(itemIdentifier: NSFileProviderItemIdentifier(itemIdentifier), progress: Progress(totalUnitCount: 1), registrar: NoopURLSessionTaskRegistrar(), cancellation: CancellationToken())
    }

    func cleanup() {
        UploadWireURLProtocol.clear()
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        try? FileManager.default.removeItem(at: storeURL)
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: storeURL.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try? FileManager.default.removeItem(at: sidecar)
            }
        }
        for sourceURL in sourceURLs {
            try? FileManager.default.removeItem(at: sourceURL)
        }
        sourceURLs.removeAll()
    }

    private static func capabilities(provider: String) -> CapabilitySnapshot {
        let providerCapability = CapabilitySnapshot.Provider(name: provider, read: .verified, write: .verified, resumable: .verified, zeroByte: .verified, crypto: .verified)
        let operations = CapabilitySnapshot.OperationCapabilities(collisionSafeCreate: .verified, conditionalModify: .verified, metadataMove: .verified, zeroByte: .verified, resumable: .verified)
        return CapabilitySnapshot(
            revision: 1,
            stableItemIdentity: .verified,
            stableRootIdentity: .verified,
            conditionalContentWrite: .verified,
            idempotentCreate: .verified,
            contentVersionSemantics: .verified,
            resumableUploadProviders: [provider],
            uploadCompletionQueryableProviders: [provider],
            zeroByteWriteProviders: [provider],
            resolvedUploadPolicyKinds: [provider],
            providers: [providerCapability],
            operations: operations
        )
    }
}

private enum WireTestError: Error {
    case cannotCreateSource
}

private final class UploadWireURLProtocol: URLProtocol {
    struct Request: Sendable {
        let url: URL
        let method: String
        let authorization: String?
        let contentType: String?
        let body: Data?

        var bodyString: String? { body.flatMap { String(data: $0, encoding: .utf8) } }
    }

    final class State: @unchecked Sendable {
        let provider: String
        let sourceSize: Int
        let mimeType: String
        private let lock = NSLock()
        private var recordedRequests: [Request] = []

        init(provider: String, sourceSize: Int, mimeType: String = "text/plain") {
            self.provider = provider
            self.sourceSize = sourceSize
            self.mimeType = mimeType
        }

        var requests: [Request] {
            lock.lock()
            defer { lock.unlock() }
            return recordedRequests
        }

        func append(_ request: Request) {
            lock.lock()
            recordedRequests.append(request)
            lock.unlock()
        }
    }

    private final class StateBox: @unchecked Sendable {
        let lock = NSLock()
        var value: State?
    }

    private static let stateBox = StateBox()

    static func install(_ state: State) {
        stateBox.lock.lock()
        stateBox.value = state
        stateBox.lock.unlock()
    }

    static func clear() {
        stateBox.lock.lock()
        stateBox.value = nil
        stateBox.lock.unlock()
    }

    private static func currentState() -> State? {
        stateBox.lock.lock()
        defer { stateBox.lock.unlock() }
        return stateBox.value
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "cloudreve.example" || request.url?.host == "storage.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let requestURL = request.url, let state = Self.currentState() else {
            client?.urlProtocol(self, didFailWithError: WireTestError.cannotCreateSource)
            return
        }
        let body = Self.body(from: request)
        state.append(Request(url: requestURL, method: request.httpMethod ?? "GET", authorization: request.value(forHTTPHeaderField: "Authorization"), contentType: request.value(forHTTPHeaderField: "Content-Type"), body: body))
        let responseBody: Data
        let statusCode: Int
        if requestURL.host == "storage.example" {
            (statusCode, responseBody) = Self.storageResponse(for: request, state: state)
        } else {
            (statusCode, responseBody) = Self.cloudreveResponse(for: request, state: state)
        }
        let response = HTTPURLResponse(url: requestURL, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !responseBody.isEmpty { client?.urlProtocol(self, didLoad: responseBody) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(from request: URLRequest) -> Data? {
        if let httpBody = request.httpBody { return httpBody }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var body = Data()
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }

    private static func cloudreveResponse(for request: URLRequest, state: State) -> (Int, Data) {
        let path = request.url?.path ?? ""
        if path == "/api/v4/file/upload" {
            let uploadURL: String
            switch state.provider {
            case "qiniu": uploadURL = "https://storage.example/qiniu/upload"
            case "upyun": uploadURL = "https://storage.example/upyun/form"
            default: uploadURL = "https://storage.example/remote/upload?session=opaque"
            }
            let credential: String
            switch state.provider {
            case "qiniu": credential = "qiniu-token"
            case "upyun": credential = "upyun-authorization"
            default: credential = "remote-token"
            }
            let policy: [String: Any] = [
                "code": 0,
                "data": [
                    "session_id": "session-\(state.provider)",
                    "expires": Int(Date().addingTimeInterval(3_600).timeIntervalSince1970),
                    "chunk_size": 4,
                    "credential": credential,
                    "upload_policy": state.provider == "upyun" ? "upyun-policy" : NSNull(),
                    "mime_type": state.mimeType,
                    "upload_urls": [uploadURL],
                    "callback_secret": NSNull(),
                    "completeURL": NSNull(),
                    "storage_policy": ["type": state.provider]
                ]
            ]
            return (200, try! JSONSerialization.data(withJSONObject: policy))
        }
        if path == "/api/v4/file/info" {
            let response: [String: Any] = [
                "code": 0,
                "data": [
                    "type": 0,
                    "id": "remote-wire-\(state.provider)",
                    "name": "payload.bin",
                    "created_at": "2026-09-05T00:00:00Z",
                    "updated_at": "2026-09-05T00:00:00Z",
                    "size": state.sourceSize,
                    "path": "/payload.bin",
                    "permission": "r",
                    "capability": "rwd",
                    "primary_entity": "entity-\(state.provider)"
                ]
            ]
            return (200, try! JSONSerialization.data(withJSONObject: response))
        }
        return (404, Data())
    }

    private static func storageResponse(for request: URLRequest, state: State) -> (Int, Data) {
        let path = request.url?.path ?? ""
        if state.provider == "qiniu", path.hasPrefix("/qiniu/upload/") {
            let number = path.split(separator: "/").last ?? "0"
            return (200, Data("{\"etag\":\"etag-\(number)\"}".utf8))
        }
        if state.provider == "qiniu", path == "/qiniu/upload" {
            return (200, Data())
        }
        if state.provider == "upyun", path == "/upyun/form" {
            return (204, Data())
        }
        if state.provider == "remote", path == "/remote/upload" {
            return (200, Data(#"{"code":0}"#.utf8))
        }
        return (404, Data())
    }
}
