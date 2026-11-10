import CryptoKit
import Foundation

/// Configured scan roots shared by apps and command-line consumers.
public struct CleanupFolder: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var url: URL
    public var preset: Preset?
    public var builtInCategoryID: String? = nil

    public init(id: UUID = UUID(), name: String, url: URL, preset: Preset? = nil, builtInCategoryID: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.preset = preset
        self.builtInCategoryID = builtInCategoryID
    }

    // Persist the package's stable preset identifiers without duplicating its catalog.
    public typealias Preset = FindingCatalog.OptionalFolder

    public var categoryID: String { builtInCategoryID ?? "userFolder:" + id.uuidString }
    public var canonicalPath: String { url.standardizedFileURL.resolvingSymlinksInPath().path }
    public var classification: CleanupClassification { preset?.classification ?? .review }
    public var explanation: String { preset?.explanation ?? "Review these files before moving them to Trash." }
    public func category() throws -> FindingCategory {
        try FindingCategory(id: categoryID, title: name, explanation: explanation, location: FilesystemPath(url), classification: classification)
    }
    /// Deterministic identity for configuration entries and catalog suggestions.
    public static func stableIdentifier(for key: String) -> UUID {
        let hash = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7], hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
    }

    /// Validate and normalize consumer configuration, including duplicate paths and IDs.
    public static func normalized(_ folders: [CleanupFolder]) throws -> [CleanupFolder] {
        var paths: Set<String> = []
        var ids: Set<UUID> = []
        return try folders.map { folder in
            guard folder.url.isFileURL, folder.url.path.hasPrefix("/"),
                  !folder.url.path.utf8.contains(0), ids.insert(folder.id).inserted else {
                throw ConfigurationError.invalidFolder
            }
            guard paths.insert(folder.canonicalPath).inserted else { throw ConfigurationError.duplicateFolder }
            var normalized = folder
            normalized.name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.name.isEmpty { normalized.name = folder.url.lastPathComponent }
            normalized.url = folder.url.standardizedFileURL
            return normalized
        }
    }

    private enum ConfigurationError: Error, LocalizedError {
        case invalidPath, invalidFolder, duplicateFolder
        var errorDescription: String? {
            switch self {
            case .invalidPath: "Cleanup folder paths must be absolute local paths without NUL characters."
            case .invalidFolder: "Choose a valid local folder with a unique identifier."
            case .duplicateFolder: "Each folder can only be added once."
            }
        }
    }

    /// Plain paths make this file easy to edit; omitted IDs stay stable across reloads.
    public struct Configuration: Codable, Sendable {
        public var version = 1
        public var _comment: String? = "Edit folders using absolute paths and developerFolders using category IDs. Reload configuration after editing. scanDepth: 0 means unlimited."
        public var developerFolders: [String]
        public var scanDepth: Int
        public var folders: [Entry]

        public init(version: Int = 1, developerFolders: [String], scanDepth: Int, folders: [Entry]) {
            self.version = version
            self.developerFolders = developerFolders
            self.scanDepth = scanDepth
            self.folders = folders
        }

        public struct Entry: Codable, Sendable {
            public var id: UUID?
            public var name: String?
            public var path: String
            public var preset: Preset?

            public init(id: UUID? = nil, name: String? = nil, path: String, preset: Preset? = nil) {
                self.id = id
                self.name = name
                self.path = path
                self.preset = preset
            }

            public func folder() throws -> CleanupFolder {
                guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw ConfigurationError.invalidPath }
                let url = URL(fileURLWithPath: path).standardizedFileURL
                let stableID = CleanupFolder.stableIdentifier(for: url.path)
                return CleanupFolder(id: id ?? stableID, name: name ?? url.lastPathComponent, url: url, preset: preset)
            }
        }
    }

}

// Custom names and paths remain editable in the shared JSON configuration.
public extension FindingCatalog.OptionalFolder {
    func folder(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> CleanupFolder {
        let category = try category(home: home)
        return CleanupFolder(id: UUID(), name: category.title, url: category.location.url, preset: self)
    }
}
