import Foundation
import FileProvider
import CloudreveDomainKit
import CloudreveStoreBridge

private struct Metric: Encodable {
    let name: String
    let samples: Int
    let warmups: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let p99Milliseconds: Double
    let maximumMilliseconds: Double
}

private struct BenchmarkReport: Encodable {
    let schemaVersion: Int
    let kind: String
    let macOS: String
    let architecture: String
    let datasetItems: Int
    let pageSize: Int
    let samples: Int
    let warmups: Int
    let metrics: [Metric]
}

@main
private struct NimbusSyncBenchmarks {
    static func main() throws {
        let itemCount = positiveEnvironmentInt("NIMBUSSYNC_BENCHMARK_ITEMS", default: 100_000)
        let pageSize = positiveEnvironmentInt("NIMBUSSYNC_BENCHMARK_PAGE_SIZE", default: 200)
        let sampleCount = positiveEnvironmentInt("NIMBUSSYNC_BENCHMARK_SAMPLES", default: 100)
        let warmupCount = min(10, sampleCount)

        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-benchmark-\(UUID().uuidString).sqlite3")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            for suffix in ["-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
            }
        }

        let store = try SQLiteStateStore(url: databaseURL)
        let domainIdentifier = CloudreveIdentifier.domain()
        let scope = try RemoteScope(origin: "https://benchmark.invalid", accountID: "benchmark", rootURI: "/")
        try store.registerDomain(DomainDescriptor(
            identifier: domainIdentifier,
            displayName: "NimbusSync benchmark",
            scope: scope,
            rootRemoteID: "benchmark-root",
            accountID: "benchmark",
            secretReference: "benchmark-reference"
        ))

        let rootIdentifier = NSFileProviderItemIdentifier.rootContainer.rawValue
        let items = try makeItems(count: itemCount, parentIdentifier: rootIdentifier, rootURI: scope.rootURI)
        for start in stride(from: 0, to: items.count, by: 1_000) {
            try store.insertItems(Array(items[start..<min(items.count, start + 1_000)]))
        }

        let directoryMetric = try measure(name: "directory_offset_page", samples: sampleCount, warmups: warmupCount) { sample in
            let maximumOffset = max(0, itemCount - pageSize)
            let offset = maximumOffset == 0 ? 0 : (sample * pageSize) % maximumOffset
            _ = try store.listChildrenPage(parentIdentifier: rootIdentifier, offset: offset, limit: pageSize)
        }

        let workingSetMetric = try measure(name: "working_set_keyset_page", samples: sampleCount, warmups: warmupCount) { sample in
            let cursorIndex = itemCount == 0 ? 0 : (sample * pageSize) % itemCount
            let cursor = cursorIndex == 0 ? nil : items[cursorIndex - 1].itemIdentifier
            _ = try store.workingSetItems(afterIdentifier: cursor, limit: pageSize)
        }

        let report = BenchmarkReport(
            schemaVersion: 1,
            kind: "nimbussync.local-store-benchmark",
            macOS: operatingSystemVersion(),
            architecture: architecture,
            datasetItems: itemCount,
            pageSize: pageSize,
            samples: sampleCount,
            warmups: warmupCount,
            metrics: [directoryMetric, workingSetMetric]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }

    private static func makeItems(count: Int, parentIdentifier: String, rootURI: String) throws -> [RemoteItem] {
        var result: [RemoteItem] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let name = String(format: "benchmark-%06d.dat", index)
            let identifier = CloudreveIdentifier.item(forTemplate: "nimbussync-benchmark-\(index)")
            let uri = try CloudreveRemoteURI.append(rootURI, name: name)
            let revision = Data("revision-\(index)".utf8)
            result.append(RemoteItem(
                itemIdentifier: identifier,
                remoteID: "benchmark-remote-\(index)",
                parentIdentifier: parentIdentifier,
                name: name,
                uri: uri,
                kind: .file,
                contentType: "public.data",
                size: 128,
                remoteVersion: "revision-\(index)",
                version: ItemVersion(content: revision, metadata: revision),
                canRead: true
            ))
        }
        return result
    }

    private static func measure(name: String, samples: Int, warmups: Int, operation: (Int) throws -> Void) rethrows -> Metric {
        for sample in 0..<warmups {
            try operation(sample)
        }
        var values: [Double] = []
        values.reserveCapacity(samples)
        for sample in 0..<samples {
            let start = DispatchTime.now().uptimeNanoseconds
            try operation(sample + warmups)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            values.append(Double(elapsed) / 1_000_000.0)
        }
        let sorted = values.sorted()
        return Metric(
            name: name,
            samples: samples,
            warmups: warmups,
            p50Milliseconds: percentile(sorted, fraction: 0.50),
            p95Milliseconds: percentile(sorted, fraction: 0.95),
            p99Milliseconds: percentile(sorted, fraction: 0.99),
            maximumMilliseconds: sorted.last ?? 0
        )
    }

    private static func percentile(_ values: [Double], fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let index = min(values.count - 1, max(0, Int(ceil(fraction * Double(values.count))) - 1))
        return values[index]
    }

    private static func positiveEnvironmentInt(_ name: String, default defaultValue: Int) -> Int {
        guard let rawValue = ProcessInfo.processInfo.environment[name], let value = Int(rawValue), value > 0 else {
            return defaultValue
        }
        return value
    }

    private static func operatingSystemVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
