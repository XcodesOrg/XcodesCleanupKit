import Darwin
import Foundation
import Testing
@testable import XcodesCleanupKit

struct ScanTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ path: URL, bytes: Int = 40_000) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 17, count: bytes).write(to: path)
    }

    @Test func defaultCatalogIsSharedAndKeepsThirdPartyCachesOptional() throws {
        let home = URL(fileURLWithPath: "/fixture-home")
        let derivedData = URL(fileURLWithPath: "/custom-builds")
        let downloads = URL(fileURLWithPath: "/custom-downloads")
        let defaults = try FindingCatalog.developer(home: home, derivedData: derivedData, xcodesDownloads: downloads)
        #expect(defaults.map(\.id) == ["derivedData", "archives", "deviceSupport", "simulators", "xcodesDownloads", "simulatorRuntimes"])
        #expect(defaults.first?.location.url == derivedData)
        #expect(defaults.first(where: { $0.id == "xcodesDownloads" })?.location.url == downloads)
        #expect(defaults.filter(\.requiresManagedInventory).map(\.id) == ["simulatorRuntimes"])
        #expect(defaults.last?.location.displayPath == "/Library/Developer/CoreSimulator")
        let optional = try FindingCatalog.general(home: home)
        #expect(Set(["npm", "cargo", "gradle", "docker"]).isSubset(of: Set(optional.map(\.id))))
        #expect(optional.first(where: { $0.id == "docker" })?.classification == .manageExternally)
    }

    @Test func optionalFolderMenuSharesMetadataWithGeneralCatalog() throws {
        let home = URL(fileURLWithPath: "/fixture-home")
        let optional = try FindingCatalog.optional(home: home)
        #expect(optional.map(\.id) == ["downloads", "backups", "appCaches", "trash", "npm", "cargo", "gradle", "docker"])
        let general = try FindingCatalog.general(home: home)
        for suggestion in optional {
            let policy = try #require(general.first { $0.id == suggestion.id })
            #expect(policy.location == suggestion.location)
            #expect(policy.title == suggestion.title)
            #expect(policy.explanation == suggestion.explanation)
            #expect(policy.classification == suggestion.classification)
        }
        #expect(optional.first?.location.displayPath == "/fixture-home/Downloads")
        #expect(try JSONDecoder().decode(FindingCatalog.OptionalFolder.self, from: Data("\"npm\"".utf8)) == .npm)
    }

    @Test func depthLimitListsImmediateItemsWithoutReadingTheirContents() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("direct"))
        try write(root.appendingPathComponent("child/nested/file"))
        let session = try ScanSession(request: ScanRequest(roots: [FilesystemPath(root)], maximumDepth: 1))
        let result = try await session.result()
        let child = try #require(result.item(at: FilesystemPath(root.appendingPathComponent("child"))))
        #expect(child.status == .depthLimited)
        #expect(child.allocatedBytes == 0)
        #expect(result.children(of: child.id).isEmpty)
        #expect(result.item(at: try FilesystemPath(root.appendingPathComponent("child/nested/file"))) == nil)
        #expect(result.progress.scannedDirectoryCount == 1)
        #expect(result.roots[0].status == .partial)
        #expect(result.progress.inaccessibleCount == 0)
        let fullSession = try ScanSession(request: ScanRequest(roots: [FilesystemPath(root)]))
        let full = try await fullSession.result()
        #expect(full.roots[0].status == .complete)
        #expect(full.roots[0].allocatedBytes > result.roots[0].allocatedBytes)
    }

    @Test func overlappingExplicitRootsRetainTheirDepthScopes() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("developer/cache/nested/file"))
        try write(root.appendingPathComponent("other/nested/file"))
        let home = try FilesystemPath(root)
        let developer = try FilesystemPath(root.appendingPathComponent("developer/cache"))
        let session = try ScanSession(request: ScanRequest(roots: [home, developer], rootDepthLimits: [home: 1]))
        let result = try await session.result()
        #expect(result.roots.count == 1)
        #expect(result.item(at: developer)?.status == .complete)
        #expect(result.item(at: try FilesystemPath(root.appendingPathComponent("developer/cache/nested/file")))?.allocatedBytes ?? 0 > 0)
        #expect(result.item(at: try FilesystemPath(root.appendingPathComponent("other")))?.status == .depthLimited)
        #expect(result.item(at: try FilesystemPath(root.appendingPathComponent("other/nested"))) == nil)
        #expect(result.roots[0].status == .partial)
        #expect(result.progress.allocatedBytes == result.roots[0].allocatedBytes)
    }

    @Test func invalidDepthIsRejected() throws {
        let root = try FilesystemPath(FileManager.default.temporaryDirectory)
        #expect(throws: ScanError.invalidDepth) { try ScanSession(request: ScanRequest(roots: [root], maximumDepth: 0)) }
        #expect(throws: ScanError.invalidDepth) { try ScanSession(request: ScanRequest(roots: [root], rootDepthLimits: [root: -1])) }
    }

    @Test func foundationConsumerCanBrowseWithoutFindings() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("project/build/output"))
        try write(root.appendingPathComponent("other"))
        let session = try ScanSession(request: ScanRequest(roots: [FilesystemPath(root)]))
        let result = try await session.result()
        #expect(result.findings.isEmpty)
        #expect(result.roots.count == 1)
        let project = try #require(result.children(of: result.rootIDs[0]).first { $0.displayName == "project" })
        let build = try #require(result.children(of: project.id).first)
        let output = try #require(result.children(of: build.id).first)
        #expect(output.allocatedBytes > 0)
        #expect(result.ancestors(of: output.id).map(\.id) == [build.id, project.id, result.rootIDs[0]])
        #expect(result.item(at: try FilesystemPath(output.path.url))?.id == output.id)
        #expect(result.progress.phase == .completed)
        #expect(result.roots[0].containedItemCount == 4)
        #expect(result.roots[0].status == .complete)
        #expect(result.progress.allocatedBytes == result.roots[0].allocatedBytes)
        var last: ScanSnapshot?
        for await snapshot in session.snapshots { last = snapshot }
        #expect(last?.progress.phase == .completed)
        #expect(last?.result?.item(output.id)?.allocatedBytes == output.allocatedBytes)
    }

    @Test func overlappingRootsAndHardLinksAreCountedOnce() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("one/file")
        let second = root.appendingPathComponent("two/link")
        try write(first)
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(link(first.path, second.path) == 0)
        let session = try ScanSession(request: ScanRequest(roots: [FilesystemPath(root), FilesystemPath(first.deletingLastPathComponent()), FilesystemPath(root)]))
        let result = try await session.result()
        #expect(result.roots.count == 1)
        let a = try #require(result.item(at: FilesystemPath(first)))
        let b = try #require(result.item(at: FilesystemPath(second)))
        let reader = DirectoryReader()
        #expect(a.allocatedBytes + b.allocatedBytes == (try reader.metadata(FilesystemPath(first))).allocatedBytes)
        #expect(try result.normalizedSelection([a.id, result.rootIDs[0], a.id]).count == 1)
        let single = try await SavingsEstimator.estimate(selection: [a.id], in: result)
        #expect(single.estimatedReclaimableBytes == 0)
        let both = try await SavingsEstimator.estimate(selection: [a.id, b.id], in: result)
        #expect(both.estimatedReclaimableBytes == a.allocatedBytes + b.allocatedBytes)
    }

    @Test func symlinksAreNotTraversedAndMissingRootsAreVisible() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("file"))
        #expect(symlink(root.path, root.appendingPathComponent("loop").path) == 0)
        let missing = root.appendingPathComponent("missing-root")
        let session = try ScanSession(request: ScanRequest(roots: [FilesystemPath(missing), FilesystemPath(root)]))
        let result = try await session.result()
        #expect(result.itemCount == 4)
        #expect(result.item(at: try FilesystemPath(root.appendingPathComponent("loop")))?.kind == .symbolicLink)
        // Explicit nonexistent roots remain visible, even inside another requested root.
        let absent = try ScanSession(request: ScanRequest(roots: [FilesystemPath(missing)]))
        let absentResult = try await absent.result()
        #expect(absentResult.roots[0].status == .inaccessible)
        #expect(absentResult.progress.inaccessibleCount == 1)
    }

    @Test func catalogAndNestedModulesKeepIndividualItems() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        try write(cache.appendingPathComponent("project-a/file"))
        try write(root.appendingPathComponent("app/node_modules/a/node_modules/nested/file"))
        try write(root.appendingPathComponent("other/node_modules/file"))
        let category = FindingCategory(id: "cache", title: "Cache", explanation: "Rebuild", location: try FilesystemPath(cache), classification: .regenerable)
        let session = try ScanSession(request: ScanRequest(roots: [FilesystemPath(root)], categories: [category], detectNodeModules: true, workerCount: 4))
        let result = try await session.result()
        #expect(result.findings.count == 2)
        let modules = try #require(result.findings.first { $0.id == "nodeModules" })
        #expect(modules.itemIDs.count == 2)
        #expect(result.children(of: try #require(result.findings.first { $0.id == "cache" }).itemIDs[0]).count == 1)
        #expect(result.findings.allSatisfy { $0.isComplete })
    }

    @Test func filenamesRemainByteExactAndCodable() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = try FilesystemPath(bytes: FilesystemPath(root).bytes + [47, 0xFF, 0xFE])
        let fd = path.withCString { open($0, O_CREAT | O_WRONLY, 0o600) }
        // APFS rejects invalid UTF-8 names. The byte-preserving model still must round-trip.
        #expect(try JSONDecoder().decode(FilesystemPath.self, from: JSONEncoder().encode(path)).bytes == path.bytes)
        if fd < 0 { #expect(errno == EILSEQ || errno == EINVAL); return }
        close(fd)
        let session = try ScanSession(request: ScanRequest(roots: [FilesystemPath(root)]))
        let result = try await session.result()
        let item = try #require(result.item(at: path))
        #expect(item.path.bytes == path.bytes)
        #expect(try JSONDecoder().decode(ScanItem.self, from: JSONEncoder().encode(item)).path == path)
        #expect(try FilesystemPath(path.url).bytes == path.bytes)
    }

    @Test func bulkMatchesReferenceAndSparseFilesUseAllocation() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<900 { try write(root.appendingPathComponent("file-\(index)"), bytes: index % 200) }
        let sparse = root.appendingPathComponent("sparse")
        let fd = open(sparse.path, O_CREAT | O_WRONLY, 0o600)
        #expect(fd >= 0); defer { if fd >= 0 { close(fd) } }
        #expect(ftruncate(fd, 100_000_000) == 0)
        let reader = DirectoryReader()
        let listing = try withoutCloudDownloads { try reader.list(reader.open(FilesystemPath(root))) }
        #expect(listing.entries.count == 901)
        let fallback = try withoutCloudDownloads { try reader.list(reader.open(FilesystemPath(root)), preferBulk: false) }
        #expect(fallback.entries.count == listing.entries.count)
        #expect(Set(fallback.entries.map(\.identity)) == Set(listing.entries.map(\.identity)))
        #expect(fallback.entries.reduce(UInt64(0)) { $0 + $1.allocatedBytes } == listing.entries.reduce(UInt64(0)) { $0 + $1.allocatedBytes })
        for entry in listing.entries {
            let reference = try reader.metadata(FilesystemPath(root).appending(entry.name))
            #expect(reference.allocatedBytes == entry.allocatedBytes)
            #expect(reference.identity == entry.identity)
        }
        #expect(try reader.metadata(FilesystemPath(sparse)).allocatedBytes < 100_000_000)
    }

    @Test func cancellationAndIndependentSessions() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<80 { try write(root.appendingPathComponent("folder-\(index)/file")) }
        let first = try ScanSession(request: ScanRequest(roots: [FilesystemPath(root)], workerCount: 2))
        let second = try ScanSession(request: ScanRequest(roots: [FilesystemPath(root)], workerCount: 3))
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.result() }
        let result = try await second.result()
        #expect(result.itemCount == 161)
        #expect(result.item(ScanItemID(scanID: first.id, index: 0)) == nil)
        #expect(DirectoryHandle.liveCount == 0 || DirectoryHandle.liveCount < 256)
    }

    @Test func unreadableDirectoriesAreNotReportedAsComplete() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let privateFolder = root.appendingPathComponent("restricted")
        try write(privateFolder.appendingPathComponent("file"))
        #expect(chmod(privateFolder.path, 0) == 0)
        defer { _ = chmod(privateFolder.path, 0o700) }
        let session = try ScanSession(request: ScanRequest(roots: [FilesystemPath(root)]))
        let result = try await session.result()
        if getuid() != 0 {
            #expect(result.item(at: try FilesystemPath(privateFolder))?.status == .inaccessible)
            #expect(result.roots[0].status == .partial)
            #expect(result.progress.inaccessibleCount > 0)
        }
    }

    @Test func cloudFlagsAreRecognizedWithoutReadingFileContent() {
        let entry = DirectoryEntry(name: Array("cloud".utf8), kind: .directory,
            identity: FileIdentity(device: 1, inode: 1), links: 1, allocatedBytes: 0, flags: UInt32(SF_DATALESS))
        #expect(entry.isCloudOnly)
    }

    @Test func policyIsRestoredAndMetadataParserRejectsTruncation() throws {
        let original = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        try withoutCloudDownloads {
            #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        }
        #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == original)
        [UInt8](repeating: 0, count: 3).withUnsafeBytes {
            var cursor = AttributeCursor(bytes: $0, offset: 0, end: 3)
            #expect(throws: ScanError.malformedMetadata) { try cursor.read(UInt64.self) }
        }
    }

    @Test func completedResultOutlivesSession() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("child/file"))
        func scan() async throws -> ScanResult {
            let session = try ScanSession(request: ScanRequest(roots: [FilesystemPath(root)]))
            let result = try await session.result()
            #expect(session.currentResult().itemCount == result.itemCount)
            return result
        }
        let result = try await scan()
        let child = try #require(result.children(of: result.rootIDs[0]).first)
        #expect(result.children(of: child.id).count == 1)
        #expect(result.item(child.id)?.containedItemCount == 1)
        #expect(try await SavingsEstimator.estimate(selection: [child.id], in: result).estimatedReclaimableBytes > 0)
    }

    @Test func replacedDirectoryIsRejectedAndDescriptorClosed() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let reader = DirectoryReader()
        let original = try reader.metadata(FilesystemPath(path)).identity
        try FileManager.default.moveItem(at: path, to: root.appendingPathComponent("original"))
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let parent = try reader.open(FilesystemPath(root))
        #expect(throws: ScanError.system(ESTALE)) {
            try reader.open(FilesystemPath(path), parent: parent, name: Array("child".utf8), expectedIdentity: original)
        }
    }

}
