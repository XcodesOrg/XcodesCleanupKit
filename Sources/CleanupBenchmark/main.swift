import Foundation
import XcodesCleanupKit

@main
struct CleanupBenchmark {
    static func main() async throws {
        let arguments = CommandLine.arguments.dropFirst()
        guard let path = arguments.first else {
            print("Usage: swift run -c release cleanup-benchmark PATH [RUNS] [WORKERS] [CATALOG_HOME]")
            return
        }
        let runs = max(1, Int(arguments.dropFirst().first ?? "5") ?? 5)
        let workers = Int(arguments.dropFirst(2).first ?? "") ?? ScanRequest.defaultWorkerCount
        let home = arguments.dropFirst(3).first.map { URL(fileURLWithPath: $0) }
        let categories = try home.map { try FindingCatalog.developer(home: $0) } ?? []
        var times: [Double] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            let session = try ScanSession(request: ScanRequest(roots: [FilesystemPath(URL(fileURLWithPath: path))], categories: categories, workerCount: workers))
            let result = try await session.result()
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            times.append(seconds)
            print("seconds=\(seconds) items=\(result.itemCount) bytes=\(result.progress.allocatedBytes) errors=\(result.progress.inaccessibleCount) first_finding_ns=\(result.progress.firstFindingElapsedNanoseconds.map(String.init) ?? "none")")
        }
        let ordered = times.sorted()
        let middle = ordered.count / 2
        let median = ordered.count.isMultiple(of: 2) ? (ordered[middle - 1] + ordered[middle]) / 2 : ordered[middle]
        print("median_seconds=\(median)")
    }
}
