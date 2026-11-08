import Foundation
import CloudreveDomainKit

public enum ActivityLevel: String, Sendable, CaseIterable {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"

    var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .error: 2
        }
    }
}

public struct ActivityEntry: Sendable, Equatable, Identifiable {
    public let date: Date
    public let level: ActivityLevel
    /// The writing process: `app` or `fileprovider`.
    public let source: String
    public let category: String
    public let message: String
    public let id: String

    public init(date: Date, level: ActivityLevel, source: String, category: String, message: String) {
        self.date = date; self.level = level; self.source = source; self.category = category; self.message = message
        self.id = "\(date.timeIntervalSince1970)|\(source)|\(category)|\(message)"
    }
}

/// A small, human-readable event log shared by the app and the File Provider extension.
///
/// Unified logging is the detailed record, but the sandboxed app cannot read the extension's
/// entries, so nothing could show the user what the two processes were doing. This log keeps only
/// the events worth surfacing (sync runs, live-update connection, API and File Provider failures),
/// one file per process under the App Group `Logs/` directory so the writers never contend, each
/// rotated at a size bound.
///
/// Messages are the same redacted strings the unified log already gets public: never file names,
/// paths, tokens or signed URLs. `SecretRedactor` runs over every line as a backstop.
public final class ActivityLog: @unchecked Sendable {
    /// Writes only from NimbusSync's own processes. Anything else (tests, tools) gets a no-op log,
    /// so it never reaches into the App Group container.
    public static let shared: ActivityLog = {
        guard let source = defaultSource() else { return ActivityLog(directory: nil, source: "none") }
        return ActivityLog(directory: AppGroupPaths.root()?.appendingPathComponent("Logs", isDirectory: true), source: source)
    }()

    public let directory: URL?
    public let source: String
    private let maximumBytes: Int
    private let queue = DispatchQueue(label: "ai.tiy.nimbussync.activity-log", qos: .utility)
    static let maximumMessageLength = 600

    public init(directory: URL?, source: String, maximumBytes: Int = 1 << 20) {
        self.directory = directory
        self.source = Self.sanitize(source, limit: 32)
        self.maximumBytes = max(256, maximumBytes)
    }

    public static func defaultSource(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String? {
        switch bundleIdentifier {
        case "ai.tiy.nimbussync": "app"
        case "ai.tiy.nimbussync.fileprovider": "fileprovider"
        default: nil
        }
    }

    public var currentFileURL: URL? { directory?.appendingPathComponent("\(source).log") }

    public func info(_ category: String, _ message: String) { record(.info, category: category, message) }
    public func warning(_ category: String, _ message: String) { record(.warning, category: category, message) }
    public func error(_ category: String, _ message: String) { record(.error, category: category, message) }

    /// Appends asynchronously; never blocks or throws into the caller.
    public func record(_ level: ActivityLevel, category: String, _ message: String, date: Date = Date()) {
        guard directory != nil else { return }
        let line = [
            Self.timestamp(date),
            level.rawValue,
            source,
            Self.sanitize(category, limit: 48),
            Self.sanitize(SecretRedactor.redact(message), limit: Self.maximumMessageLength)
        ].joined(separator: "\t") + "\n"
        queue.async { [self] in append(line) }
    }

    /// Waits for pending writes; for tests and for reading right after writing.
    public func flush() { queue.sync {} }

    /// The newest entries across every process's files, oldest first.
    public func recent(limit: Int = 50, minimumLevel: ActivityLevel = .info) -> [ActivityEntry] {
        guard let directory, limit > 0,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var entries: [ActivityEntry] = []
        for name in names where name.hasSuffix(".log") {
            entries += Self.tailEntries(of: directory.appendingPathComponent(name)).filter { $0.level.rank >= minimumLevel.rank }
        }
        entries.sort { $0.date < $1.date }
        return Array(entries.suffix(limit))
    }

    /// The newest raw lines across every process's files, oldest first, exactly as written.
    ///
    /// Every line starts with an ISO-8601 timestamp, so ordering the text orders by time; nothing
    /// is parsed, and lines this version could not parse still show.
    public func recentLines(limit: Int = 100) -> [String] {
        guard let directory, limit > 0,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var lines: [String] = []
        for name in names where name.hasSuffix(".log") {
            lines += Self.tailLines(of: directory.appendingPathComponent(name))
        }
        lines.sort()
        return Array(lines.suffix(limit))
    }

    // MARK: - Writing

    private func append(_ line: String) {
        guard let directory, let url = currentFileURL else { return }
        let data = Data(line.utf8)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > 0, size + data.count > maximumBytes {
                let rotated = directory.appendingPathComponent("\(source).1.log")
                try? FileManager.default.removeItem(at: rotated)
                try FileManager.default.moveItem(at: url, to: rotated)
            }
            let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            // One write per line: O_APPEND keeps whole lines intact even if another writer shares
            // the file.
            _ = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        } catch {
            // Logging must never take the caller down.
        }
    }

    // MARK: - Reading

    static let tailBytes = 256 * 1024

    static func tailEntries(of url: URL) -> [ActivityEntry] {
        tailLines(of: url).compactMap(parse)
    }

    static func tailLines(of url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd() else { return [] }
        // A tail read usually starts mid-line (possibly mid-character): skip to the next line.
        if start > 0 {
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return [] }
            data = data[data.index(after: newline)...]
        }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    static func parse(_ line: String) -> ActivityEntry? {
        let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5, let date = parseTimestamp(fields[0]), let level = ActivityLevel(rawValue: fields[1]) else { return nil }
        return ActivityEntry(date: date, level: level, source: fields[2], category: fields[3], message: fields[4])
    }

    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }

    static func timestamp(_ date: Date) -> String { formatter().string(from: date) }
    static func parseTimestamp(_ value: String) -> Date? { formatter().date(from: value) }

    static func sanitize(_ value: String, limit: Int) -> String {
        let flattened = value.map { character -> Character in
            character == "\t" || character.isNewline ? " " : character
        }
        let string = String(flattened)
        return string.count > limit ? String(string.prefix(limit - 1)) + "…" : string
    }
}
