import Foundation

public struct CleanupFinding: Identifiable, Sendable, Codable {
    public let id: String
    public let categoryID: String
    public let title: String
    public let explanation: String
    public let classification: CleanupClassification
    public let itemIDs: [ScanItemID]
    public let allocatedBytes: UInt64
    public let isComplete: Bool
}
