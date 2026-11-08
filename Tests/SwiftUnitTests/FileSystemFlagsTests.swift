import XCTest
import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveFileProviderKit

/// Items used to publish `fileSystemFlags = []`, which the system turned into
/// mode 0100 folders: Finder badged them as inaccessible and could not open
/// them. These tests pin the POSIX bits to the item capabilities.
final class FileSystemFlagsTests: XCTestCase {
    private func item(kind: RemoteItemKind, canRead: Bool = true, canWrite: Bool = false, canAddChildren: Bool = false) -> RemoteItem {
        RemoteItem(
            remoteID: "remote-\(kind.rawValue)",
            parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
            name: kind == .folder ? "folder" : "file.txt",
            uri: kind == .folder ? "/folder" : "/file.txt",
            kind: kind,
            contentType: kind == .folder ? UTType.folder.identifier : "public.plain-text",
            version: ItemVersion(content: Data("c".utf8), metadata: Data("m".utf8)),
            canRead: canRead,
            canWrite: canWrite,
            canAddChildren: canAddChildren
        )
    }

    func testWritableFolderIsReadableWritableAndTraversable() {
        let flags = NimbusSyncFileProviderItem(model: item(kind: .folder, canWrite: true, canAddChildren: true)).fileSystemFlags
        XCTAssertTrue(flags.contains(.userReadable))
        XCTAssertTrue(flags.contains(.userWritable))
        XCTAssertTrue(flags.contains(.userExecutable))
    }

    func testReadOnlyFolderStaysReadableAndTraversable() {
        let flags = NimbusSyncFileProviderItem(model: item(kind: .folder)).fileSystemFlags
        XCTAssertEqual(flags, [.userReadable, .userExecutable])
    }

    func testFolderThatOnlyAcceptsChildrenIsWritable() {
        let flags = NimbusSyncFileProviderItem(model: item(kind: .folder, canAddChildren: true)).fileSystemFlags
        XCTAssertTrue(flags.contains(.userWritable))
    }

    func testUnreadableFolderIsOnlyTraversable() {
        let flags = NimbusSyncFileProviderItem(model: item(kind: .folder, canRead: false)).fileSystemFlags
        XCTAssertEqual(flags, [.userExecutable])
    }

    func testFileFlagsFollowReadAndWriteCapabilities() {
        XCTAssertEqual(NimbusSyncFileProviderItem(model: item(kind: .file, canWrite: true)).fileSystemFlags, [.userReadable, .userWritable])
        XCTAssertEqual(NimbusSyncFileProviderItem(model: item(kind: .file)).fileSystemFlags, [.userReadable])
        XCTAssertFalse(NimbusSyncFileProviderItem(model: item(kind: .file, canWrite: true)).fileSystemFlags.contains(.userExecutable))
    }

    func testProjectionRevisionChangesMetadataVersionForFlagRepublish() {
        // Cached items only pick up the new flags if their metadata version
        // changes, which the projection revision feeds into.
        XCTAssertGreaterThanOrEqual(ProjectionSchema.currentRevision, 4)
    }

    func testDiagnosticSummaryKeepsStageAndRedactsPayloads() {
        let failure = CoreFailure(code: .unknownOutcome, retryable: false, redactedContext: ["stage": "directory_snapshot_cursor"])
        XCTAssertEqual(FileProviderErrorMapper.diagnosticSummary(failure), "core:unknown_outcome stage=directory_snapshot_cursor")

        let sql = StoreBridgeError.sql("INSERT INTO items VALUES ('secret-name.txt')")
        let summary = FileProviderErrorMapper.diagnosticSummary(sql)
        XCTAssertEqual(summary, "store:sql")
        XCTAssertFalse(summary.contains("secret-name"))

        struct Probe: Decodable { let files: [String] }
        do {
            _ = try JSONDecoder().decode(Probe.self, from: Data("{\"data\":1}".utf8))
            XCTFail("decode should fail")
        } catch {
            XCTAssertEqual(FileProviderErrorMapper.diagnosticSummary(error), "decoding:key_not_found:files path=")
        }
    }

    func testURIDiagnosticShapeDescribesStructureWithoutNames() {
        let shape = CloudreveRemoteURI.diagnosticShape("cloudreve://acct42@my/%E5%B7%A5%E4%BD%9C/secret%20plan+v2#x")
        XCTAssertTrue(shape.contains("fragment"))
        XCTAssertTrue(shape.contains("user"))
        XCTAssertTrue(shape.contains("host=my"))
        XCTAssertTrue(shape.contains("+"))
        XCTAssertFalse(shape.contains("secret"))
        XCTAssertFalse(shape.contains("acct42"))
        XCTAssertFalse(shape.contains("plan"))
        XCTAssertTrue(CloudreveRemoteURI.diagnosticShape("/plain/name").contains("bare_path"))
        XCTAssertTrue(CloudreveRemoteURI.diagnosticShape("cloudreve://my/a?b").contains("query"))
    }

    func testMappedCodeIsUnchangedByDiagnostics() {
        let mapped = FileProviderErrorMapper.map(CoreFailure(code: .unknownOutcome, retryable: false))
        XCTAssertEqual(mapped.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(mapped.code, NSFileProviderError.cannotSynchronize.rawValue)
    }
}
