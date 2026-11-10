import Darwin
import Foundation

struct StoredNode: Sendable {
    var name: [UInt8]
    var parent: Int?
    var children: [Int] = []
    var rootPath: FilesystemPath?
    var kind: ScanItemKind
    var identity: FileIdentity
    var allocatedBytes: UInt64
    var containedItemCount: UInt64 = 0
    var status: ScanItemStatus
    var errorCode: Int32?
}

/// Immutable and queryable without retaining the session. No UI or terminal formatting is involved.
public struct ScanResult: Sendable {
    public let scanID: UUID
    public let rootIDs: [ScanItemID]
    public let findings: [CleanupFinding]
    public let progress: ScanProgress
    let nodes: [StoredNode]

    public var itemCount: Int { nodes.count }
    public var roots: [ScanItem] { rootIDs.compactMap(item) }

    public func item(_ id: ScanItemID) -> ScanItem? {
        guard id.scanID == scanID, nodes.indices.contains(id.index) else { return nil }
        let node = nodes[id.index]
        return ScanItem(id: id, parentID: node.parent.map(makeID), path: path(id.index),
                        displayName: node.parent == nil ? path(id.index).displayName : String(decoding: node.name, as: UTF8.self),
                        kind: node.kind, identity: node.identity, allocatedBytes: node.allocatedBytes,
                        containedItemCount: node.containedItemCount, status: node.status, errorCode: node.errorCode)
    }

    public func children(of id: ScanItemID) -> [ScanItem] {
        guard id.scanID == scanID, nodes.indices.contains(id.index) else { return [] }
        return nodes[id.index].children.map(makeID).compactMap(item)
    }

    /// Immediate parent first, scan root last.
    public func ancestors(of id: ScanItemID) -> [ScanItem] {
        guard id.scanID == scanID, nodes.indices.contains(id.index) else { return [] }
        var ancestors: [ScanItem] = []
        var parent = nodes[id.index].parent
        while let index = parent { if let value = item(makeID(index)) { ancestors.append(value) }; parent = nodes[index].parent }
        return ancestors
    }

    public func item(at path: FilesystemPath) -> ScanItem? {
        guard let root = rootIDs.filter({ self.path($0.index).contains(path) })
            .max(by: { self.path($0.index).bytes.count < self.path($1.index).bytes.count }) else { return nil }
        var index = root.index
        let suffix = path.bytes.dropFirst(self.path(index).bytes.count)
        for component in suffix.split(separator: 47) {
            guard let child = nodes[index].children.first(where: { nodes[$0].name.elementsEqual(component) }) else { return nil }
            index = child
        }
        return item(makeID(index))
    }

    /// Removes duplicates and descendants already covered by selected ancestors.
    public func normalizedSelection(_ ids: [ScanItemID]) throws -> [ScanItem] {
        var items: [ScanItem] = []
        for id in Set(ids) {
            guard let value = item(id) else { throw ScanError.invalidItem }
            items.append(value)
        }
        let sorted = items.sorted { $0.path.bytes.count < $1.path.bytes.count }
        var selected: [ScanItem] = []
        for value in sorted {
            // Explicit mounted roots are separate trees; an excluded mount beneath
            // another selected root does not cover the explicitly scanned volume.
            var parent = nodes[value.id.index].parent
            var covered = false
            while let index = parent {
                if selected.contains(where: { $0.id.index == index }) { covered = true; break }
                parent = nodes[index].parent
            }
            if !covered { selected.append(value) }
        }
        return selected
    }

    /// Inspect unfinished branches only; completed subtrees have no access failures.
    public func hasAccessDeniedEntries(in rootID: ScanItemID) -> Bool {
        guard rootID.scanID == scanID, nodes.indices.contains(rootID.index) else { return false }
        var pending = [rootID.index]
        while let index = pending.popLast() {
            let node = nodes[index]
            if node.errorCode == EACCES || node.errorCode == EPERM { return true }
            guard node.kind == .directory, node.status == .partial || node.status == .scanning else { continue }
            pending.append(contentsOf: node.children.filter { nodes[$0].status != .complete })
        }
        return false
    }

    /// Completed top-level cleanup candidates, without consumer sorting or selection policy.
    public func cleanupItems(for category: FindingCategory) -> [ScanItem] {
        guard let root = item(at: category.location) else { return [] }
        return categoryItems([root], categoryID: category.id)
    }

    public func cleanupItems(for finding: CleanupFinding) -> [ScanItem] {
        let roots = finding.itemIDs.compactMap(item)
        if finding.categoryID == "nodeModules" || finding.classification == .manageExternally {
            return roots.filter { $0.status != .scanning }
        }
        return categoryItems(roots, categoryID: finding.categoryID)
    }

    private func categoryItems(_ roots: [ScanItem], categoryID: String) -> [ScanItem] {
        roots.flatMap { $0.kind == .directory ? children(of: $0.id) : [$0] }.filter { value in
            guard value.status != .scanning else { return false }
            switch categoryID {
            case "xcodesDownloads":
                let name = value.displayName.lowercased()
                return value.kind == .file && [".xip", ".dmg", ".pkg"].contains { name.hasSuffix($0) }
            case "simulators":
                return value.kind == .directory && UUID(uuidString: value.displayName) != nil
            default:
                return true
            }
        }
    }

    func makeID(_ index: Int) -> ScanItemID { ScanItemID(scanID: scanID, index: index) }
    func path(_ index: Int) -> FilesystemPath {
        var names: [[UInt8]] = []
        var current = index
        while let parent = nodes[current].parent { names.append(nodes[current].name); current = parent }
        var result = nodes[current].rootPath!
        for name in names.reversed() { result = result.appending(name) }
        return result
    }
}
