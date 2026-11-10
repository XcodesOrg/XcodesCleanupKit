import Darwin
import Foundation

/// Identifiers are scoped to a session UUID; they remain stable through that session's snapshots.
public struct ScanItemID: Hashable, Sendable, Codable {
    public let scanID: UUID
    public let index: Int
    public init(scanID: UUID, index: Int) { self.scanID = scanID; self.index = index }
}

public enum ScanItemKind: String, Sendable, Codable { case directory, file, symbolicLink, other }
public enum ScanItemStatus: String, Sendable, Codable { case scanning, complete, partial, inaccessible, cloudOnly, mountExcluded, depthLimited }

public struct FileIdentity: Hashable, Sendable, Codable {
    public let device: UInt64
    public let inode: UInt64
    public init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }
}

public struct ScanItem: Identifiable, Sendable, Codable {
    public let id: ScanItemID
    public let parentID: ScanItemID?
    public let path: FilesystemPath
    public let displayName: String
    public let kind: ScanItemKind
    public let identity: FileIdentity
    /// Hard-linked files contribute allocated bytes once across a scan. Attribution can vary by worker order.
    public let allocatedBytes: UInt64
    public let containedItemCount: UInt64
    public let status: ScanItemStatus
    public let errorCode: Int32?

    /// Permission failures are distinct from missing files or depth-limited results.
    public var isAccessDenied: Bool { errorCode == EACCES || errorCode == EPERM }
}
