import Darwin
import Foundation
import os

struct DirectoryEntry: Sendable {
    var name: [UInt8]
    var kind: ScanItemKind
    var identity: FileIdentity
    var links: UInt64
    var allocatedBytes: UInt64
    var flags: UInt32
    var isMount: Bool = false
    var sharingFlags: UInt64? = nil
    var isCloudOnly: Bool { flags & UInt32(SF_DATALESS) != 0 }
}

/// Immutable descriptor ownership; ARC closes it after the last queued child has opened.
final class DirectoryHandle: @unchecked Sendable {
    private static let count = OSAllocatedUnfairLock(initialState: 0)
    static var liveCount: Int { count.withLock { $0 } }
    let descriptor: Int32
    init(_ descriptor: Int32) { self.descriptor = descriptor; Self.count.withLock { $0 += 1 } }
    deinit { close(descriptor); Self.count.withLock { $0 -= 1 } }
}

struct DirectoryListing {
    var entries: [DirectoryEntry] = []
    var errors: UInt64 = 0
}

struct AttributeCursor {
    let bytes: UnsafeRawBufferPointer
    var offset: Int
    let end: Int

    @inline(__always)
    mutating func read<T>(_ type: T.Type) throws -> T {
        guard offset >= 0, MemoryLayout<T>.size <= end - offset else { throw ScanError.malformedMetadata }
        let value = bytes.loadUnaligned(fromByteOffset: offset, as: T.self)
        offset += MemoryLayout<T>.size
        return value
    }
}

/// One reader per blocking worker. Its buffer never crosses a thread boundary.
final class DirectoryReader {
    private var buffer = [UInt8](repeating: 0, count: 32 * 1024)
    static let openFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW

    func open(_ path: FilesystemPath, parent: DirectoryHandle? = nil, name: [UInt8]? = nil, expectedIdentity: FileIdentity? = nil) throws -> DirectoryHandle {
        var fd: Int32 = -1
        if let parent, let name {
            fd = (name + [0]).withUnsafeBytes {
                openat(parent.descriptor, $0.baseAddress!.assumingMemoryBound(to: CChar.self), Self.openFlags)
            }
        }
        if fd < 0 { fd = path.withCString { Darwin.open($0, Self.openFlags) } }
        guard fd >= 0 else { throw ScanError.system(errno) }
        let handle = DirectoryHandle(fd)
        if let expectedIdentity {
            var metadata = stat()
            guard fstat(fd, &metadata) == 0 else { throw ScanError.system(errno) }
            let identity = FileIdentity(device: UInt64(UInt32(bitPattern: metadata.st_dev)), inode: metadata.st_ino)
            guard identity == expectedIdentity else { throw ScanError.system(ESTALE) }
        }
        return handle
    }

    // Fetch metadata in batches; use ordinary directory listing when bulk access is unsupported.
    func list(_ directory: DirectoryHandle, sharing: Bool = false, preferBulk: Bool = true, cancelled: () -> Bool = { false }) throws -> DirectoryListing {
        if !preferBulk { return try fallback(directory, cancelled: cancelled) }
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FLAGS | ATTR_CMN_FILEID)
        attributes.dirattr = UInt32(ATTR_DIR_MOUNTSTATUS | ATTR_DIR_ALLOCSIZE)
        attributes.fileattr = UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)
        if sharing { attributes.forkattr = UInt32(ATTR_CMNEXT_EXT_FLAGS) }
        var listing = DirectoryListing()
        while !cancelled() {
            let count = buffer.withUnsafeMutableBytes {
                getattrlistbulk(directory.descriptor, &attributes, $0.baseAddress!, $0.count,
                                sharing ? UInt64(FSOPT_ATTR_CMN_EXTENDED) : 0)
            }
            if count < 0 {
                let code = errno
                // Discard partial bulk records and restart from the beginning in the fallback.
                if [ENOTSUP, EINVAL, ENOSYS].contains(code) { return try fallback(directory, cancelled: cancelled) }
                throw ScanError.system(code)
            }
            if count == 0 { break } // A short batch does NOT mean end of enumeration.
            try buffer.withUnsafeBytes { bytes in
                var start = 0
                for _ in 0..<count {
                    var header = AttributeCursor(bytes: bytes, offset: start, end: bytes.count)
                    let length = Int(try header.read(UInt32.self))
                    guard length >= 4, length <= bytes.count - start else { throw ScanError.malformedMetadata }
                    var cursor = AttributeCursor(bytes: bytes, offset: start + 4, end: start + length)
                    let returned = try cursor.read(attribute_set_t.self)
                    if returned.commonattr & UInt32(ATTR_CMN_ERROR) != 0 {
                        let code = try cursor.read(UInt32.self)
                        if code != 0 { listing.errors += 1; start += length; continue }
                    }
                    guard returned.commonattr & UInt32(ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FLAGS | ATTR_CMN_FILEID) == UInt32(ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FLAGS | ATTR_CMN_FILEID) else {
                        listing.errors += 1; start += length; continue
                    }
                    let referenceOffset = cursor.offset
                    let reference = try cursor.read(attrreference_t.self)
                    let nameStart = referenceOffset + Int(reference.attr_dataoffset)
                    let nameLength = Int(reference.attr_length)
                    guard nameLength > 1, nameStart >= start, nameStart <= start + length,
                          nameLength <= start + length - nameStart, bytes[nameStart + nameLength - 1] == 0 else { throw ScanError.malformedMetadata }
                    let name = Array(bytes[nameStart..<(nameStart + nameLength - 1)])
                    guard name.allSatisfy({ $0 != 0 && $0 != 47 }), name != [46], name != [46, 46] else { throw ScanError.malformedMetadata }
                    let device = UInt64(UInt32(bitPattern: try cursor.read(dev_t.self)))
                    let objectType = try cursor.read(UInt32.self)
                    let flags = try cursor.read(UInt32.self)
                    let inode = try cursor.read(UInt64.self)
                    let kind: ScanItemKind = objectType == 2 ? .directory : objectType == 5 ? .symbolicLink : objectType == 1 ? .file : .other
                    var mount = false
                    var size: UInt64 = 0
                    var links: UInt64 = 1
                    if kind == .directory {
                        if returned.dirattr & UInt32(ATTR_DIR_MOUNTSTATUS) != 0 { mount = try cursor.read(UInt32.self) & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0 }
                        guard returned.dirattr & UInt32(ATTR_DIR_ALLOCSIZE) != 0 else { listing.errors += 1; start += length; continue }
                        size = UInt64(max(0, try cursor.read(Int64.self)))
                    } else {
                        if returned.fileattr & UInt32(ATTR_FILE_LINKCOUNT) != 0 { links = UInt64(try cursor.read(UInt32.self)) }
                        guard returned.fileattr & UInt32(ATTR_FILE_ALLOCSIZE) != 0 else { listing.errors += 1; start += length; continue }
                        size = UInt64(max(0, try cursor.read(Int64.self)))
                    }
                    let extendedFlags: UInt64? = returned.forkattr & UInt32(ATTR_CMNEXT_EXT_FLAGS) != 0 ? try cursor.read(UInt64.self) : nil
                    listing.entries.append(DirectoryEntry(name: name, kind: kind,
                        identity: FileIdentity(device: device, inode: inode), links: links,
                        allocatedBytes: size, flags: flags, isMount: mount, sharingFlags: extendedFlags))
                    start += length
                }
            }
        }
        if cancelled() { throw CancellationError() }
        return listing
    }

    private func fallback(_ directory: DirectoryHandle, cancelled: () -> Bool) throws -> DirectoryListing {
        // Open a fresh file description; dup() would share the bulk reader's directory offset.
        let fd = openat(directory.descriptor, ".", Self.openFlags)
        guard fd >= 0 else { throw ScanError.system(errno) }
        guard let stream = fdopendir(fd) else { close(fd); throw ScanError.system(errno) }
        defer { closedir(stream) }
        var listing = DirectoryListing()
        while !cancelled() {
            errno = 0
            guard let pointer = readdir(stream) else {
                if errno != 0 { throw ScanError.system(errno) }
                break
            }
            var record = pointer.pointee
            let name = withUnsafeBytes(of: &record.d_name) { Array($0.prefix(Int(record.d_namlen))) }
            if name == [46] || name == [46, 46] { continue }
            var metadata = stat()
            let status = (name + [0]).withUnsafeBytes {
                fstatat(directory.descriptor, $0.baseAddress!.assumingMemoryBound(to: CChar.self), &metadata, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else { listing.errors += 1; continue }
            var value = Self.entry(metadata, name: name)
            if value.kind == .directory {
                value.allocatedBytes = (try? allocation(directory: directory.descriptor, name: name)) ?? value.allocatedBytes
            }
            listing.entries.append(value)
        }
        if cancelled() { throw CancellationError() }
        return listing
    }

    static func entry(_ metadata: stat, name: [UInt8]) -> DirectoryEntry {
        let type = metadata.st_mode & mode_t(S_IFMT)
        let kind: ScanItemKind = type == S_IFDIR ? .directory : type == S_IFLNK ? .symbolicLink : type == S_IFREG ? .file : .other
        return DirectoryEntry(name: name, kind: kind,
            identity: FileIdentity(device: UInt64(UInt32(bitPattern: metadata.st_dev)), inode: metadata.st_ino),
            links: UInt64(metadata.st_nlink), allocatedBytes: UInt64(max(0, metadata.st_blocks)) * 512,
            flags: metadata.st_flags)
    }

    func metadata(_ path: FilesystemPath) throws -> DirectoryEntry {
        var metadata = stat()
        guard path.withCString({ lstat($0, &metadata) }) == 0 else { throw ScanError.system(errno) }
        var entry = Self.entry(metadata, name: Array(path.bytes.split(separator: 47).last ?? []))
        if entry.kind == .directory { entry.allocatedBytes = (try? allocation(path: path)) ?? entry.allocatedBytes }
        return entry
    }

    func allocation(path: FilesystemPath) throws -> UInt64 {
        try attributes(path: path, directory: nil, name: nil, fork: 0, directoryAttributes: UInt32(ATTR_DIR_ALLOCSIZE)).directoryAllocation!
    }

    func allocation(directory: Int32, name: [UInt8]) throws -> UInt64 {
        try attributes(path: nil, directory: directory, name: name, fork: 0, directoryAttributes: UInt32(ATTR_DIR_ALLOCSIZE)).directoryAllocation!
    }

    struct Sharing {
        var flags: UInt64?
        var privateBytes: UInt64?
        var cloneID: UInt64?
        var referenceCount: UInt32?
        var directoryAllocation: UInt64?
    }

    func sharing(_ path: FilesystemPath, attributes requested: UInt32) throws -> Sharing {
        try attributes(path: path, directory: nil, name: nil, fork: requested, directoryAttributes: 0)
    }

    private func attributes(path: FilesystemPath?, directory: Int32?, name: [UInt8]?, fork: UInt32, directoryAttributes: UInt32) throws -> Sharing {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        attributes.dirattr = directoryAttributes
        attributes.forkattr = fork
        var bytes = [UInt8](repeating: 0, count: 256)
        let options = UInt32(FSOPT_NOFOLLOW) | (fork == 0 ? 0 : UInt32(FSOPT_ATTR_CMN_EXTENDED))
        let status = bytes.withUnsafeMutableBytes { buffer in
            if let directory, let name {
                return (name + [0]).withUnsafeBytes {
                    getattrlistat(directory, $0.baseAddress!.assumingMemoryBound(to: CChar.self), &attributes,
                                  buffer.baseAddress!, buffer.count, UInt(options))
                }
            }
            return path!.withCString { getattrlist($0, &attributes, buffer.baseAddress!, buffer.count, options) }
        }
        guard status == 0 else { throw ScanError.system(errno) }
        return try bytes.withUnsafeBytes { buffer in
            var header = AttributeCursor(bytes: buffer, offset: 0, end: buffer.count)
            let length = Int(try header.read(UInt32.self))
            guard length <= buffer.count, length >= 4 else { throw ScanError.malformedMetadata }
            var cursor = AttributeCursor(bytes: buffer, offset: 4, end: length)
            let returned = try cursor.read(attribute_set_t.self)
            guard returned.forkattr & fork == fork, returned.dirattr & directoryAttributes == directoryAttributes else { throw ScanError.system(ENOTSUP) }
            var result = Sharing()
            if directoryAttributes != 0 { result.directoryAllocation = UInt64(max(0, try cursor.read(Int64.self))) }
            if fork & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 { result.privateBytes = UInt64(max(0, try cursor.read(Int64.self))) }
            if fork & UInt32(ATTR_CMNEXT_CLONEID) != 0 { result.cloneID = try cursor.read(UInt64.self) }
            if fork & UInt32(ATTR_CMNEXT_EXT_FLAGS) != 0 { result.flags = try cursor.read(UInt64.self) }
            if fork & UInt32(ATTR_CMNEXT_CLONE_REFCNT) != 0 { result.referenceCount = try cursor.read(UInt32.self) }
            return result
        }
    }
}

/// Must wrap synchronous work: suspending inside this scope could migrate to another thread.
func withoutCloudDownloads<T>(_ operation: () throws -> T) throws -> T {
    let original = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
    guard original >= 0, setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
        throw ScanError.cloudPolicyUnavailable(errno)
    }
    defer { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, original) }
    return try operation()
}
