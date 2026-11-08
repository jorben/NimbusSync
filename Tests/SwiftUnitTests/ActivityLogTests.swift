import XCTest
import Foundation
import CloudreveObservability

final class ActivityLogTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-activity-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testEntriesFromBothProcessesMergeInTimeOrder() {
        let app = ActivityLog(directory: directory, source: "app")
        let extensionLog = ActivityLog(directory: directory, source: "fileprovider")
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        app.record(.info, category: "reconciliation", "reconcile.started", date: base)
        extensionLog.record(.error, category: "file-provider-error", "fp.error.mapped fp_code=-2005", date: base.addingTimeInterval(1))
        app.record(.warning, category: "remote-events", "sse.stream.failed", date: base.addingTimeInterval(2))
        app.flush(); extensionLog.flush()

        let entries = app.recent()
        XCTAssertEqual(entries.map(\.message), ["reconcile.started", "fp.error.mapped fp_code=-2005", "sse.stream.failed"])
        XCTAssertEqual(entries.map(\.source), ["app", "fileprovider", "app"])
        XCTAssertEqual(entries[1].level, .error)
        XCTAssertEqual(entries[0].date.timeIntervalSince1970, base.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(app.recent(minimumLevel: .warning).map(\.message), ["fp.error.mapped fp_code=-2005", "sse.stream.failed"])
        XCTAssertEqual(app.recent(limit: 1).map(\.message), ["sse.stream.failed"])
    }

    func testLinesStayParsableAndSecretsAreRedacted() throws {
        let log = ActivityLog(directory: directory, source: "app")
        log.record(.error, category: "api\tbad", "line one\nline two\tAuthorization: Bearer abc.def access_token=xyz")
        log.flush()
        let entry = try XCTUnwrap(log.recent().last)
        XCTAssertEqual(entry.category, "api bad")
        XCTAssertFalse(entry.message.contains("\n"))
        XCTAssertFalse(entry.message.contains("abc.def"))
        XCTAssertFalse(entry.message.contains("xyz"))
        let raw = try String(contentsOf: XCTUnwrap(log.currentFileURL), encoding: .utf8)
        XCTAssertEqual(raw.split(separator: "\n").count, 1, "one event is exactly one line")
    }

    func testFilesRotateAtTheSizeBoundAndKeepTheNewestEntries() throws {
        let log = ActivityLog(directory: directory, source: "app", maximumBytes: 512)
        for index in 0..<60 { log.record(.info, category: "test", "event \(index) " + String(repeating: "x", count: 40)) }
        log.flush()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(files, ["app.1.log", "app.log"])
        for name in files {
            let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.size] as? Int)
            XCTAssertLessThanOrEqual(size, 512)
        }
        XCTAssertEqual(log.recent(limit: 1).first?.message.hasPrefix("event 59 "), true)
    }

    func testTailReadSkipsThePartialFirstLine() throws {
        let log = ActivityLog(directory: directory, source: "app", maximumBytes: 8 << 20)
        let longMessage = String(repeating: "多", count: 200)
        for _ in 0..<1_200 { log.record(.info, category: "test", longMessage) }
        log.record(.error, category: "test", "last")
        log.flush()
        let entries = log.recent(limit: 5_000)
        XCTAssertFalse(entries.isEmpty)
        XCTAssertLessThan(entries.count, 1_201, "only the tail is read")
        XCTAssertEqual(entries.last?.message, "last")
    }

    func testSharedLogIsInertOutsideNimbusSyncProcesses() {
        XCTAssertNil(ActivityLog.defaultSource(bundleIdentifier: "com.apple.dt.xctest.tool"))
        XCTAssertEqual(ActivityLog.defaultSource(bundleIdentifier: "ai.tiy.nimbussync"), "app")
        XCTAssertEqual(ActivityLog.defaultSource(bundleIdentifier: "ai.tiy.nimbussync.fileprovider"), "fileprovider")
        XCTAssertNil(ActivityLog.shared.directory, "tests must never write into the App Group container")
    }
}
