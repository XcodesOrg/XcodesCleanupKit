import Foundation
import Darwin

/// Defines read-only traversal scope and optional findings; consumers own presentation and cleanup.
public struct ScanRequest: Sendable {
    /// Metadata walking contends on filesystem locks. Prefer performance cores on
    /// heterogeneous Macs; callers can override this for measured workloads.
    public static var defaultWorkerCount: Int {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &cores, &size, nil, 0) == 0, cores > 0 {
            return min(64, Int(cores))
        }
        return max(1, min(64, ProcessInfo.processInfo.activeProcessorCount))
    }

    public let roots: [FilesystemPath]
    public let categories: [FindingCategory]
    public let detectNodeModules: Bool
    public let workerCount: Int
    /// Root is level 0. A limit of 1 lists immediate entries without opening child directories.
    /// Nil means unlimited. Explicit overlapping roots retain their own scan scope.
    public let maximumDepth: Int?
    /// Overrides the default for specific requested roots; unspecified roots use maximumDepth.
    public let rootDepthLimits: [FilesystemPath: Int]

    public init(roots: [FilesystemPath], categories: [FindingCategory] = [], detectNodeModules: Bool = false,
                workerCount: Int = ScanRequest.defaultWorkerCount, maximumDepth: Int? = nil,
                rootDepthLimits: [FilesystemPath: Int] = [:]) {
        self.roots = roots; self.categories = categories; self.detectNodeModules = detectNodeModules
        self.workerCount = workerCount
        self.maximumDepth = maximumDepth; self.rootDepthLimits = rootDepthLimits
    }
}
