import Foundation

/// Suggested locations, not authority to delete. Callers decide which categories to enable.
public enum FindingCatalog {
    /// Shared default folders, including managed runtimes. Pass configured paths from any app or CLI.
    public static func developer(home: URL, derivedData: URL? = nil, xcodesDownloads: URL? = nil) throws -> [FindingCategory] {
        var categories = try [
            category("derivedData", "Xcode build files", "Xcode rebuilds these on the next build. Close Xcode before cleanup.", .regenerable, derivedData ?? home.appendingPathComponent("Library/Developer/Xcode/DerivedData")),
            category("archives", "Xcode archives", "Keep archives and dSYMs needed to distribute builds or symbolicate crash reports.", .review, home.appendingPathComponent("Library/Developer/Xcode/Archives")),
            category("deviceSupport", "Device support", "Xcode may need to download or prepare support files again when a device connects.", .regenerable, home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport")),
            category("simulators", "Simulator devices", "Simulator devices may be shared by installed Xcodes. Device deletion permanently removes its apps and data.", .simulatorDevice, home.appendingPathComponent("Library/Developer/CoreSimulator/Devices"))
        ]
        if let xcodesDownloads {
            categories.append(try category("xcodesDownloads", "Xcodes downloads", "Review completed installer archives. Active downloads and installations are protected.", .review, xcodesDownloads))
        }
        categories.append(try category("simulatorRuntimes", "Simulator runtimes", "Managed by CoreSimulator", .manageExternally,
            URL(fileURLWithPath: "/Library/Developer/CoreSimulator"), requiresManagedInventory: true))
        return categories
    }

    /// Optional folders that consumers can offer in addition to the shared developer defaults.
    public static func general(home: URL, userTemporaryDirectory: URL? = nil) throws -> [FindingCategory] {
        var categories = try optional(home: home)
        categories += try [
            category("movies", "Movies", "Review videos and editing projects before cleanup.", .review, home.appendingPathComponent("Movies")),
            category("mail", "Mail", "Manage mail and attachments in Mail rather than deleting its storage directory.", .manageExternally, home.appendingPathComponent("Library/Mail"))
        ]
        if let userTemporaryDirectory {
            categories.append(try category("chromeLeftovers", "Chrome update leftovers", "Close Chrome before moving obsolete update copies to Trash.", .review,
                                           userTemporaryDirectory.appendingPathComponent("X/com.google.Chrome.code_sign_clone")))
        }
        return categories
    }

    /// Choices for an Add Folder menu, shared by graphical and command-line consumers.
    public static func optional(home: URL) throws -> [FindingCategory] {
        try OptionalFolder.allCases.map { try $0.category(home: home) }
    }

    /// Stable identifiers can be persisted; all suggested metadata lives in this package.
    public enum OptionalFolder: String, CaseIterable, Codable, Identifiable, Sendable {
        case downloads, backups, appCaches, trash, npm, cargo, gradle, docker

        public var id: String { rawValue }
        public var title: String { definition.title }
        public var explanation: String { definition.explanation }
        public var classification: CleanupClassification { definition.classification }

        public func category(home: URL) throws -> FindingCategory {
            try FindingCatalog.category(rawValue, title, explanation, classification,
                                        home.appendingPathComponent(definition.path))
        }

        private var definition: (title: String, explanation: String, classification: CleanupClassification, path: String) {
            switch self {
            case .downloads:
                ("Downloads", "Review personal files and installers before moving them to Trash.", .review, "Downloads")
            case .backups:
                ("iPhone and iPad backups", "Manage device backups in Finder; these may be your only copies.", .manageExternally, "Library/Application Support/MobileSync/Backup")
            case .appCaches:
                ("App caches", "Apps may regenerate these files. Close the owning app before cleanup.", .review, "Library/Caches")
            case .trash:
                ("Trash", "Review and empty Trash in Finder to reclaim space. Xcodes does not empty it.", .manageExternally, ".Trash")
            case .npm:
                ("npm cache", "Packages will be downloaded again when needed.", .regenerable, ".npm/_cacache")
            case .cargo:
                ("Cargo registry", "Dependencies will be downloaded and rebuilt when needed.", .regenerable, ".cargo/registry")
            case .gradle:
                ("Gradle caches", "Gradle will rebuild or download these caches. Stop Gradle daemons first.", .regenerable, ".gradle/caches")
            case .docker:
                ("Docker storage", "Manage images, containers and volumes with Docker. Do not delete Docker's storage directory.", .manageExternally, "Library/Containers/com.docker.docker")
            }
        }
    }

    private static func category(_ id: String, _ title: String, _ explanation: String, _ classification: CleanupClassification, _ url: URL, requiresManagedInventory: Bool = false) throws -> FindingCategory {
        FindingCategory(id: id, title: title, explanation: explanation, location: try FilesystemPath(url), classification: classification, requiresManagedInventory: requiresManagedInventory)
    }
}
