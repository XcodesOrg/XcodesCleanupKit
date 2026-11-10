import Foundation
import Testing
import XcodesCleanupKit

struct CleanupFolderTests {
    @Test func publicConfigurationPreservesCustomPathsAndPresetPolicies() throws {
        let entry = CleanupFolder.Configuration.Entry(name: "My backups", path: "/fixture/custom-backups", preset: .backups)
        let configuration = CleanupFolder.Configuration(developerFolders: ["derivedData"], scanDepth: 1, folders: [entry])
        let data = try JSONEncoder().encode(configuration)
        let restored = try JSONDecoder().decode(CleanupFolder.Configuration.self, from: data)
        let folder = try #require(restored.folders.first).folder()
        #expect(folder.name == "My backups")
        #expect(folder.url.path == "/fixture/custom-backups")
        #expect(folder.classification == .manageExternally)
        #expect(folder.id == (try entry.folder().id))
        #expect(try folder.category().explanation == FindingCatalog.OptionalFolder.backups.explanation)
        #expect(restored.scanDepth == 1)
        #expect(restored.developerFolders == ["derivedData"])
    }

    @Test func publicSuggestionsAndPathValidation() throws {
        let home = URL(fileURLWithPath: "/fixture")
        let folder = try FindingCatalog.OptionalFolder.npm.folder(home: home)
        #expect(folder.url.path == "/fixture/.npm/_cacache")
        #expect(folder.classification == .regenerable)
        #expect(throws: (any Error).self) {
            try CleanupFolder.Configuration.Entry(path: "relative/path").folder()
        }
        #expect(throws: (any Error).self) {
            try CleanupFolder.Configuration.Entry(path: "/invalid\0path").folder()
        }
    }
}
