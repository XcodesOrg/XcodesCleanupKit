import Darwin
import Foundation
import os

public enum SavingsLimitation: String, Hashable, Sendable, Codable {
    case snapshotsMayRetainBlocks, partialCloneSharing, inaccessibleMetadata, cloudOnly, mountExcluded, sharingMetadataUnavailable
}

public struct SavingsEstimate: Sendable, Codable {
    public let estimatedReclaimableBytes: UInt64
    public let selectedAllocatedBytes: UInt64
    public let isComplete: Bool
    public let limitations: Set<SavingsLimitation>
}

/// Read-only estimates for deletion, not for moving files into Trash.
public enum SavingsEstimator {
    public static func estimate(selection: [ScanItemID], in result: ScanResult) async throws -> SavingsEstimate {
        let items = try result.normalizedSelection(selection)
        let cancellation = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue(label: "org.xcodes.cleanup.savings", qos: .userInitiated).async {
                    do {
                        let value = try withoutCloudDownloads {
                            try SavingsSurvey(items: items, cancelled: { cancellation.withLock { $0 } }).run()
                        }
                        continuation.resume(returning: value)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.withLock { $0 = true } }
    }
}

private final class SavingsSurvey {
    struct SelectedFile {
        let path: FilesystemPath
        let entry: DirectoryEntry
        var selectedLinks: UInt64
        let apfs: Bool
    }
    struct CloneKey: Hashable { let device: UInt64; let cloneID: UInt64 }
    struct CloneFamily { var selected: UInt32 = 0; var references: UInt32 = 0; var bytes: UInt64 = 0 }
    let items: [ScanItem]
    let cancelled: () -> Bool
    let reader = DirectoryReader()
    var files: [FileIdentity: SelectedFile] = [:]
    var work: [(DirectoryEntry, FilesystemPath, UInt64, Bool)] = []
    var reclaimed: UInt64 = 0
    var limitations: Set<SavingsLimitation> = []

    init(items: [ScanItem], cancelled: @escaping () -> Bool) { self.items = items; self.cancelled = cancelled }

    func run() throws -> SavingsEstimate {
        for item in items {
            try checkCancellation()
            if item.status != .complete { limitations.insert(.inaccessibleMetadata) }
            do {
                let metadata = try reader.metadata(item.path)
                guard metadata.identity == item.identity else { limitations.insert(.inaccessibleMetadata); continue }
                var volume = statfs()
                guard item.path.withCString({ statfs($0, &volume) }) == 0 else { throw ScanError.system(errno) }
                let apfs = withUnsafeBytes(of: volume.f_fstypename) {
                    String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) == "apfs"
                }
                if apfs { limitations.insert(.snapshotsMayRetainBlocks) }
                try record(metadata, path: item.path, rootDevice: metadata.identity.device, apfs: apfs)
            } catch is CancellationError { throw CancellationError() }
            catch { limitations.insert(.inaccessibleMetadata) }
        }
        while let (entry, path, device, apfs) = work.popLast() {
            do { try record(entry, path: path, rootDevice: device, apfs: apfs) }
            catch is CancellationError { throw CancellationError() }
            catch { limitations.insert(.inaccessibleMetadata) }
        }
        var families: [CloneKey: CloneFamily] = [:]
        for file in files.values {
            try checkCancellation()
            guard file.selectedLinks >= file.entry.links else { continue }
            if !file.apfs || file.entry.kind != .file { reclaimed += file.entry.allocatedBytes; continue }
            do {
                let sharing = try reader.sharing(file.path, attributes: UInt32(ATTR_CMNEXT_EXT_FLAGS))
                guard let flags = sharing.flags else { limitations.insert(.sharingMetadataUnavailable); continue }
                if flags & 1 == 0 { reclaimed += file.entry.allocatedBytes }
                else if flags & 0x40 != 0 {
                    let details = try reader.sharing(file.path, attributes: UInt32(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT))
                    guard let cloneID = details.cloneID, let references = details.referenceCount, references > 0 else { limitations.insert(.sharingMetadataUnavailable); continue }
                    let key = CloneKey(device: file.entry.identity.device, cloneID: cloneID)
                    var family = families[key] ?? CloneFamily()
                    family.selected += 1; family.references = max(family.references, references)
                    family.bytes = max(family.bytes, file.entry.allocatedBytes)
                    families[key] = family
                } else {
                    let details = try reader.sharing(file.path, attributes: UInt32(ATTR_CMNEXT_PRIVATESIZE))
                    guard let size = details.privateBytes else { limitations.insert(.sharingMetadataUnavailable); continue }
                    reclaimed += min(size, file.entry.allocatedBytes)
                    // Private bytes are a conservative bound; jointly selected partial clones can free more.
                    limitations.insert(.partialCloneSharing)
                }
            } catch { limitations.insert(.sharingMetadataUnavailable) }
        }
        for family in families.values where family.selected >= family.references { reclaimed += family.bytes }
        let incomplete = limitations.subtracting([.snapshotsMayRetainBlocks])
        return SavingsEstimate(estimatedReclaimableBytes: reclaimed,
            selectedAllocatedBytes: items.reduce(0) { $0 + $1.allocatedBytes }, isComplete: incomplete.isEmpty, limitations: limitations)
    }

    private func checkCancellation() throws { if cancelled() { throw CancellationError() } }

    private func record(_ entry: DirectoryEntry, path: FilesystemPath, rootDevice: UInt64, apfs: Bool) throws {
        try checkCancellation()
        if entry.isCloudOnly { limitations.insert(.cloudOnly); return }
        if entry.kind != .directory {
            if var existing = files[entry.identity] { existing.selectedLinks += 1; files[entry.identity] = existing }
            else { files[entry.identity] = SelectedFile(path: path, entry: entry, selectedLinks: 1, apfs: apfs) }
            return
        }
        if entry.isMount || entry.identity.device != rootDevice { limitations.insert(.mountExcluded); return }
        reclaimed += entry.allocatedBytes
        let directory = try reader.open(path, expectedIdentity: entry.identity)
        let listing = try reader.list(directory, cancelled: cancelled)
        if listing.errors > 0 { limitations.insert(.inaccessibleMetadata) }
        for child in listing.entries {
            work.append((child, path.appending(child.name), rootDevice, apfs))
        }
    }
}
