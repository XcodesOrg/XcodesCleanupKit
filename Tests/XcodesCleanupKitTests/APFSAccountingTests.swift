import Darwin
import Foundation
import Testing
@testable import XcodesCleanupKit

struct APFSAccountingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["XCODES_CLEANUP_APFS_TESTS"] == "1"))
    func cloneEstimateMatchesDeletionOnDisposableVolume() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-apfs-\(UUID())")
        let mount = folder.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("accounting.sparseimage")
        try run("/usr/bin/hdiutil", ["create", "-size", "128m", "-fs", "APFS", "-volname", "CleanupAccounting", "-type", "SPARSE", "-o", image.path])
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-mountpoint", mount.path, image.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path]) }
        let mountSession = try ScanSession(request: ScanRequest(roots: [FilesystemPath(folder), FilesystemPath(mount)]))
        let mountedResult = try await mountSession.result()
        #expect(mountedResult.rootIDs.count == 2)
        #expect(mountedResult.progress.mountExcludedCount == 1)
        #expect(mountedResult.item(at: try FilesystemPath(mount))?.status == .complete)
        #expect(try mountedResult.normalizedSelection(mountedResult.rootIDs).count == 2)
        #expect(mountedResult.roots.first { $0.path == (try? FilesystemPath(mount)) }?.status == .complete)
        let original = mount.appendingPathComponent("original")
        let clone1 = mount.appendingPathComponent("clone1")
        let clone2 = mount.appendingPathComponent("clone2")
        // Nonzero, varying data avoids compression and zero-block optimizations.
        let data = Data((0..<(2 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 17) })
        try data.write(to: original)
        try run("/bin/cp", ["-c", original.path, clone1.path])
        try run("/bin/cp", ["-c", original.path, clone2.path])
        let session = try ScanSession(request: ScanRequest(roots: [FilesystemPath(mount)]))
        let result = try await session.result()
        let ids = try [original, clone1, clone2].map { try #require(result.item(at: FilesystemPath($0))).id }
        let single = try await SavingsEstimator.estimate(selection: [ids[1]], in: result)
        #expect(single.estimatedReclaimableBytes == 0)
        let all = try await SavingsEstimator.estimate(selection: ids, in: result)
        #expect(all.isComplete)
        let before = try volumeUsed(mount)
        for file in [original, clone1, clone2] { try FileManager.default.removeItem(at: file) }
        let after = try volumeUsed(mount)
        #expect(before - after == all.estimatedReclaimableBytes)

        // Partial clones: private bytes must not overstate the measured saving.
        try data.write(to: original)
        try run("/bin/cp", ["-c", original.path, clone1.path])
        let handle = try FileHandle(forWritingTo: clone1)
        try handle.write(contentsOf: Data(repeating: 3, count: 32 * 1024))
        try handle.synchronize(); try handle.close()
        let secondSession = try ScanSession(request: ScanRequest(roots: [FilesystemPath(mount)]))
        let second = try await secondSession.result()
        let partialID = try #require(second.item(at: FilesystemPath(clone1))).id
        let partial = try await SavingsEstimator.estimate(selection: [partialID], in: second)
        let partialBefore = try volumeUsed(mount)
        try FileManager.default.removeItem(at: clone1)
        let partialAfter = try volumeUsed(mount)
        #expect(partial.estimatedReclaimableBytes <= partialBefore - partialAfter)
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ScanError.system(EIO) }
    }

    private func volumeUsed(_ mount: URL) throws -> UInt64 {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        attributes.volattr = UInt32(ATTR_VOL_SPACEUSED)
        var bytes = [UInt8](repeating: 0, count: 128)
        let status = bytes.withUnsafeMutableBytes { buffer in
            mount.withUnsafeFileSystemRepresentation { getattrlist($0!, &attributes, buffer.baseAddress!, buffer.count, 0) }
        }
        guard status == 0 else { throw ScanError.system(errno) }
        return try bytes.withUnsafeBytes {
            var cursor = AttributeCursor(bytes: $0, offset: 4, end: $0.count)
            let returned = try cursor.read(attribute_set_t.self)
            guard returned.volattr & UInt32(ATTR_VOL_SPACEUSED) != 0 else { throw ScanError.system(ENOTSUP) }
            return try cursor.read(UInt64.self)
        }
    }
}
