import Foundation

public enum ScanError: Error, Sendable, Equatable, LocalizedError {
    case invalidPath
    case noRoots
    case invalidDepth
    case invalidWorkerCount
    case invalidItem
    case system(Int32)
    case malformedMetadata
    case cloudPolicyUnavailable(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidPath: "A scan requires an absolute filesystem path without NUL bytes."
        case .noRoots: "Choose at least one folder to scan."
        case .invalidDepth: "Scan depth must be at least 1, or unlimited."
        case .invalidWorkerCount: "The worker count must be between 1 and 64."
        case .invalidItem: "The item does not belong to this scan result."
        case .system(let code): String(cString: strerror(code))
        case .malformedMetadata: "The filesystem returned an invalid metadata record."
        case .cloudPolicyUnavailable(let code): "Could not prevent cloud downloads: \(String(cString: strerror(code)))"
        }
    }
}
