import Foundation

/// Read-only classification shared by consumers. It does not authorize cleanup operations.
public struct CleanupPolicy: Sendable {
    private let categories: [FindingCategory]
    private let findings: [ScanItemID: CleanupClassification]

    public init(categories: [FindingCategory], findings: [CleanupFinding]) {
        self.categories = categories
        self.findings = Dictionary(findings.flatMap { finding in
            finding.itemIDs.map { ($0, finding.classification) }
        }, uniquingKeysWith: { _, latest in latest })
    }

    public func classification(for item: ScanItem, in result: ScanResult?) -> CleanupClassification {
        // Protect managed storage even when a consumer scans its parent folder.
        if categories.contains(where: {
            $0.classification == .manageExternally && ($0.location.contains(item.path) || item.path.contains($0.location))
        }) { return .manageExternally }
        if categories.contains(where: { $0.id == "simulators" && $0.location.contains(item.path) }) {
            return .simulatorDevice
        }
        var current: ScanItem? = item
        while let node = current {
            if let classification = findings[node.id] { return classification }
            current = node.parentID.flatMap { result?.item($0) }
        }
        return .review
    }
}
