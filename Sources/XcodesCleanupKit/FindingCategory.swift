import Foundation

public enum CleanupClassification: String, Sendable, Codable {
    case regenerable, review, manageExternally, simulatorDevice
}

/// A caller-supplied location. Xcodes supplies its configured paths; CLI clients can supply their own.
public struct FindingCategory: Identifiable, Sendable, Codable {
    public let id: String
    public let title: String
    public let explanation: String
    public let location: FilesystemPath
    public let classification: CleanupClassification
    /// Managed storage (such as simulator runtimes) is inventoried by the consumer, not walked as a default root.
    public let requiresManagedInventory: Bool

    public init(id: String, title: String, explanation: String, location: FilesystemPath, classification: CleanupClassification, requiresManagedInventory: Bool = false) {
        self.id = id; self.title = title; self.explanation = explanation
        self.location = location; self.classification = classification
        self.requiresManagedInventory = requiresManagedInventory
    }
}
