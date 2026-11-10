import Foundation

/// Version information is read once on a worker, never during row layout.
public enum CleanupOSMetadata {
    public static func filterName(_ name: String) -> String? {
        let parts = name.split(separator: " ")
        guard parts.count == 2, ["iOS", "tvOS", "watchOS", "visionOS", "macOS"].contains(String(parts[0])),
              let major = parts[1].split(separator: ".").first, Int(major) != nil else { return nil }
        return String(parts[0]) + " " + major
    }

    public static func deviceSupportVersion(_ name: String) -> String? {
        // Xcode uses both “18.5 (build)” and “iPhone18,1 27.0 (build)”.
        let words = name.split(separator: " ")
        guard let version = words.first(where: { value in
            let numbers = value.split(separator: ".", omittingEmptySubsequences: false)
            return !numbers.isEmpty && numbers.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        }) else { return nil }
        return "iOS " + version
    }

    public static func read(_ requests: [(item: ScanItem, category: String)]) async -> [ScanItemID: String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Metadata inspection must not materialize cloud-only files.
                let versions = (try? withoutCloudDownloads { readSynchronously(requests) }) ?? [:]
                continuation.resume(returning: versions)
            }
        }
    }

    private static func readSynchronously(_ requests: [(item: ScanItem, category: String)]) -> [ScanItemID: String] {
        var versions: [ScanItemID: String] = [:]
        for (item, category) in requests {
            let root = item.path.url
            if category == "deviceSupport", item.kind == .directory {
                versions[item.id] = deviceSupportVersion(item.displayName)
            } else if category == "backups", let info = plist(root.appendingPathComponent("Info.plist")),
                      let version = info["Product Version"] as? String {
                versions[item.id] = "iOS " + version
            } else if category == "archives", item.displayName.hasSuffix(".xcarchive"),
                      let archive = plist(root.appendingPathComponent("Info.plist")),
                      let properties = archive["ApplicationProperties"] as? [String: Any],
                      let path = properties["ApplicationPath"] as? String {
                let products = root.appendingPathComponent("Products").standardizedFileURL
                let app = products.appendingPathComponent(path).standardizedFileURL
                guard app.path.hasPrefix(products.path + "/"),
                      let info = plist(app.appendingPathComponent("Info.plist")),
                      let platform = info["DTPlatformName"] as? String,
                      let version = info["DTPlatformVersion"] as? String else { continue }
                let names = ["iphoneos": "iOS", "iphonesimulator": "iOS", "appletvos": "tvOS", "appletvsimulator": "tvOS",
                             "watchos": "watchOS", "watchsimulator": "watchOS", "xros": "visionOS", "xrsimulator": "visionOS", "macosx": "macOS"]
                if let name = names[platform] { versions[item.id] = name + " " + version }
            }
        }
        return versions
    }

    private static func plist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
