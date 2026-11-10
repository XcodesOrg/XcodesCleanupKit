import Foundation

/// Absolute POSIX bytes, excluding the terminating NUL. Display text is never used for I/O.
public struct FilesystemPath: Hashable, Sendable, Codable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.first == 47, !bytes.contains(0) else { throw ScanError.invalidPath }
        var parts: [[UInt8]] = []
        for component in bytes.split(separator: 47) {
            if component == [46] { continue }
            if component == [46, 46] { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(Array(component))
        }
        self.bytes = parts.isEmpty ? [47] : [47] + parts.joined(separator: [47])
    }

    public init(_ url: URL) throws {
        guard url.isFileURL else { throw ScanError.invalidPath }
        self = try url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { throw ScanError.invalidPath }
            return try Self(bytes: Array(UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: strlen(pointer))))
        }
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(bytes: values.decode([UInt8].self, forKey: .bytes))
    }

    public var displayPath: String { String(decoding: bytes, as: UTF8.self) }
    public var displayName: String { String(decoding: bytes.split(separator: 47).last ?? [], as: UTF8.self) }
    public var url: URL {
        withCString { URL(fileURLWithFileSystemRepresentation: $0, isDirectory: false, relativeTo: nil) }
    }

    public func contains(_ other: Self) -> Bool {
        self == other || (other.bytes.starts(with: bytes) && (bytes == [47] || other.bytes.dropFirst(bytes.count).first == 47))
    }

    private init(validatedBytes: [UInt8]) { self.bytes = validatedBytes }

    func appending(_ name: [UInt8]) -> Self {
        // Directory records are already validated. Do not re-split every ancestor component.
        var combined = bytes
        combined.reserveCapacity(bytes.count + name.count + 1)
        if bytes != [47] { combined.append(47) }
        combined.append(contentsOf: name)
        return Self(validatedBytes: combined)
    }

    func withCString<T>(_ body: (UnsafePointer<CChar>) throws -> T) rethrows -> T {
        try (bytes + [0]).withUnsafeBytes { try body($0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
    }
}
