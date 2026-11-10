import Foundation
import Testing
import XcodesCleanupKit

struct SharedCleanupTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writePlist(_ values: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: url)
    }

    @Test func cleanupCandidatesAndPolicyAreUsableWithoutAppTypes() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads.appendingPathComponent("folder.pkg"), withIntermediateDirectories: true)
        for name in ["Xcode.XIP", "installer.dmg", "download.partial"] {
            try Data("fixture".utf8).write(to: downloads.appendingPathComponent(name))
        }
        let devices = root.appendingPathComponent("devices")
        let deviceID = UUID().uuidString
        try FileManager.default.createDirectory(at: devices.appendingPathComponent(deviceID), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: devices.appendingPathComponent("unrecognized"), withIntermediateDirectories: true)
        let backups = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let base = FindingCategory(id: "fixture", title: "Fixture", explanation: "", location: try FilesystemPath(root), classification: .regenerable)
        let downloadCategory = FindingCategory(id: "xcodesDownloads", title: "Downloads", explanation: "", location: try FilesystemPath(downloads), classification: .review)
        let deviceCategory = FindingCategory(id: "simulators", title: "Devices", explanation: "", location: try FilesystemPath(devices), classification: .simulatorDevice)
        let backupCategory = FindingCategory(id: "backups", title: "Backups", explanation: "", location: try FilesystemPath(backups), classification: .manageExternally)
        let session = try ScanSession(request: ScanRequest(roots: [base.location], categories: [base]))
        let result = try await session.result()
        #expect(Set(result.cleanupItems(for: downloadCategory).map(\.displayName)) == ["Xcode.XIP", "installer.dmg"])
        #expect(result.cleanupItems(for: deviceCategory).map(\.displayName) == [deviceID])
        let policy = CleanupPolicy(categories: [deviceCategory, backupCategory], findings: result.findings)
        let file = try #require(result.item(at: FilesystemPath(downloads.appendingPathComponent("Xcode.XIP"))))
        let device = try #require(result.item(at: FilesystemPath(devices.appendingPathComponent(deviceID))))
        #expect(policy.classification(for: file, in: result) == .regenerable)
        #expect(policy.classification(for: device, in: result) == .simulatorDevice)
        #expect(policy.classification(for: result.roots[0], in: result) == .manageExternally)
        #expect(!result.hasAccessDeniedEntries(in: result.rootIDs[0]))
    }

    @Test func metadataReadsVersionsAndRejectsEscapingArchivePaths() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("valid.xcarchive")
        let invalid = root.appendingPathComponent("invalid.xcarchive")
        let backup = root.appendingPathComponent("backup")
        try writePlist(["ApplicationProperties": ["ApplicationPath": "Applications/Test.app"]], to: archive.appendingPathComponent("Info.plist"))
        try writePlist(["DTPlatformName": "xros", "DTPlatformVersion": "26.1"], to: archive.appendingPathComponent("Products/Applications/Test.app/Info.plist"))
        try writePlist(["ApplicationProperties": ["ApplicationPath": "../../outside.app"]], to: invalid.appendingPathComponent("Info.plist"))
        try writePlist(["DTPlatformName": "iphoneos", "DTPlatformVersion": "99.0"], to: root.appendingPathComponent("outside.app/Info.plist"))
        try writePlist(["Product Version": "17.6.1"], to: backup.appendingPathComponent("Info.plist"))
        let session = try ScanSession(request: ScanRequest(roots: [FilesystemPath(root)]))
        let result = try await session.result()
        let validItem = try #require(result.item(at: FilesystemPath(archive)))
        let invalidItem = try #require(result.item(at: FilesystemPath(invalid)))
        let backupItem = try #require(result.item(at: FilesystemPath(backup)))
        let versions = await CleanupOSMetadata.read([(validItem, "archives"), (invalidItem, "archives"), (backupItem, "backups")])
        #expect(versions[validItem.id] == "visionOS 26.1")
        #expect(versions[invalidItem.id] == nil)
        #expect(versions[backupItem.id] == "iOS 17.6.1")
        #expect(CleanupOSMetadata.deviceSupportVersion("iPhone18,1 27.0 (build)") == "iOS 27.0")
        #expect(CleanupOSMetadata.filterName("visionOS 26.1") == "visionOS 26")
    }

    @Test func normalizedFoldersRejectDuplicatesAndKeepCustomSettings() throws {
        let root = URL(fileURLWithPath: "/fixture")
        let folder = CleanupFolder(name: "  Downloads  ", url: root.appendingPathComponent("Downloads/../Downloads"), preset: .downloads)
        let normalized = try CleanupFolder.normalized([folder])
        #expect(normalized[0].name == "Downloads")
        #expect(normalized[0].url.path == "/fixture/Downloads")
        #expect(normalized[0].id == folder.id)
        #expect(normalized[0].preset == .downloads)
        #expect(throws: (any Error).self) {
            try CleanupFolder.normalized([folder, CleanupFolder(name: "Duplicate", url: root.appendingPathComponent("Downloads"))])
        }
        #expect(throws: (any Error).self) { try CleanupFolder.normalized([folder, folder]) }
        #expect(throws: (any Error).self) {
            try CleanupFolder.normalized([CleanupFolder(name: "Remote", url: URL(string: "https://example.com")!)])
        }
    }
}
