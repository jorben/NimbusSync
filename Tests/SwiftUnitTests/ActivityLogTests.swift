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

    func testRecentLinesAreRawTextMergedInTimeOrderAndBounded() throws {
        let app = ActivityLog(directory: directory, source: "app")
        let extensionLog = ActivityLog(directory: directory, source: "fileprovider")
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        app.record(.info, category: "sync", "first", date: base)
        extensionLog.record(.error, category: "file-provider", "second", date: base.addingTimeInterval(1))
        app.record(.warning, category: "live-updates", "third", date: base.addingTimeInterval(2))
        app.flush(); extensionLog.flush()
        // A line from an older or foreign format is still shown, just not parsed.
        let foreign = "9999-not-a-timestamp free text\n"
        let handle = try FileHandle(forWritingTo: XCTUnwrap(app.currentFileURL))
        try handle.seekToEnd(); try handle.write(contentsOf: Data(foreign.utf8)); try handle.close()

        let lines = app.recentLines()
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines.map { $0.split(separator: "\t").last.map(String.init) }, ["first", "second", "third", "9999-not-a-timestamp free text"])
        XCTAssertTrue(lines[1].contains("\tERROR\tfileprovider\tfile-provider\t"), "lines are returned exactly as written")
        XCTAssertEqual(app.recentLines(limit: 2).count, 2)
        XCTAssertEqual(app.recentLines(limit: 2).first?.hasSuffix("third"), true)
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

    func testMinimumLevelFromSharedDefaultsFiltersEveryLevel() throws {
        let suite = "ActivityLogTests.level.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = ActivityLog(directory: directory, source: "app", levelDefaults: defaults)

        XCTAssertEqual(log.minimumLevel, .info, "Info is the default")
        var built = false
        log.debug("test", { built = true; return "hidden" }())
        XCTAssertFalse(built, "debug text is not even built below the minimum level")
        log.info("test", "info shown")

        defaults.set(ActivityLevel.debug.rawValue, forKey: ActivityLogLevelPreference.preferenceKey)
        XCTAssertTrue(log.isEnabled(.debug))
        log.debug("test", "debug shown")

        defaults.set(ActivityLevel.error.rawValue, forKey: ActivityLogLevelPreference.preferenceKey)
        log.info("test", "info hidden")
        log.warning("test", "warning hidden")
        log.error("test", "error shown")

        defaults.set("bogus", forKey: ActivityLogLevelPreference.preferenceKey)
        XCTAssertEqual(log.minimumLevel, ActivityLogLevelPreference.defaultValue, "an unknown value falls back to the default")
        log.flush()

        let entries = log.recent(minimumLevel: .debug)
        XCTAssertEqual(entries.map(\.message), ["info shown", "debug shown", "error shown"])
        XCTAssertEqual(entries.map(\.level), [.info, .debug, .error], "DEBUG lines parse back")
        XCTAssertEqual(log.recent().map(\.message), ["info shown", "error shown"], "reading from Info hides debug lines")
    }

    func testLogWithoutLevelDefaultsKeepsEveryLevel() {
        let log = ActivityLog(directory: directory, source: "app")
        XCTAssertEqual(log.minimumLevel, .debug)
        log.debug("test", "kept")
        log.flush()
        XCTAssertEqual(log.recent(minimumLevel: .debug).map(\.message), ["kept"])
    }

    func testSharedLogIsInertOutsideNimbusSyncProcesses() {
        XCTAssertNil(ActivityLog.defaultSource(bundleIdentifier: "com.apple.dt.xctest.tool"))
        XCTAssertEqual(ActivityLog.defaultSource(bundleIdentifier: "ai.tiy.nimbussync"), "app")
        XCTAssertEqual(ActivityLog.defaultSource(bundleIdentifier: "ai.tiy.nimbussync.fileprovider"), "fileprovider")
        XCTAssertNil(ActivityLog.shared.directory, "tests must never write into the App Group container")
    }
}
