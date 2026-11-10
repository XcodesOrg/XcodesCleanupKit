import Foundation

public enum ScanPhase: String, Sendable, Codable { case hotspots, scanning, completed, cancelled, failed }

public struct ScanProgress: Sendable, Codable {
    public let phase: ScanPhase
    public let scannedFileCount: UInt64
    public let scannedDirectoryCount: UInt64
    public let allocatedBytes: UInt64
    public let inaccessibleCount: UInt64
    public let cloudOnlyCount: UInt64
    public let mountExcludedCount: UInt64
    /// Time from session startup to the first complete, nonempty catalog finding.
    public let firstFindingElapsedNanoseconds: UInt64?
    /// No reliable denominator is available for arbitrary roots.
    public var fractionCompleted: Double? { nil }
}

public struct ScanSnapshot: Sendable {
    public let scanID: UUID
    public let progress: ScanProgress
    public let findings: [CleanupFinding]
    /// Queryable hierarchy as of this snapshot. Large snapshots are emitted only on request/completion.
    public let result: ScanResult?
}
