# XcodesCleanupKit

A read-only macOS disk scanner for Xcodes and future CLI consumers. It requires Swift 6.2 and macOS 13 or later, with no SwiftUI, AppKit presentation, or XcodesKit dependency.

Add [XcodesCleanupKit](https://github.com/XcodesOrg/XcodesCleanupKit) in Xcode, or add it to your Swift package dependencies:

```swift
.package(url: "https://github.com/XcodesOrg/XcodesCleanupKit.git", from: "1.0.0")
```

Use the `XcodesCleanupKit` library product in your target.

## Usage

```swift
import Foundation
import XcodesCleanupKit

let root = try FilesystemPath(URL(fileURLWithPath: "/path/to/project"))
let session = try ScanSession(request: ScanRequest(
    roots: [root], detectNodeModules: true, maximumDepth: 1
))
let observer = Task {
    for await snapshot in session.snapshots {
        print(snapshot.progress.scannedFileCount)
    }
}
let result = try await session.result()
await observer.value
for folder in result.roots {
    for item in result.children(of: folder.id) {
        print(item.displayName, item.allocatedBytes, item.status)
    }
}
// Call session.cancel() to stop a scan.
```

Apps consume the same asynchronous snapshots and format their own UI. A future CLI can sort items, print raw counts, or encode `ScanItem` with `JSONEncoder`; the existing Xcodes CLI is unchanged.

- **Results:** immutable, Sendable, and usable after the session finishes. Browse roots/children, look up items by ID or path, and navigate ancestors. General folder results do not require cleanup findings.
- **Paths and values:** original POSIX path bytes are preserved separately from display text. Sizes are allocated bytes, not formatted strings; identifiers belong to one scan.
- **Defaults:** `FindingCatalog.developer(...)` is the shared default list: build files, archives, device support, simulator devices, Xcodes downloads when supplied, and simulator runtimes. Filter `requiresManagedInventory` out of filesystem roots and inventory those categories through your own integration. `FindingCatalog.optional(home:)` supplies Add Folder choices; `FindingCatalog.OptionalFolder` owns their stable IDs, names, paths, descriptions, and cleanup classifications. `general(...)` includes these choices plus additional review locations.
- **Folder configuration:** `CleanupFolder` and its Codable `Configuration` share custom roots, preset policies, and stable identifiers. `OptionalFolder.folder(home:)` creates a suggested folder. `CleanupFolder.normalized(...)` validates local roots and rejects duplicates. Consumers own file storage and when to reload it.
- **Findings:** pass categories from `FindingCatalog.developer(...)`, `FindingCatalog.general(...)`, or your own locations. Categories annotate requested roots; they do not scan extra locations automatically or authorize deletion.
- **Shared queries:** `ScanResult.cleanupItems(for:)` returns top-level cleanup candidates; `CleanupPolicy` classifies findings and protected managed locations. `CleanupOSMetadata.read(...)` reads archive, backup, and device-support versions off the main thread. `ScanItem.isAccessDenied` and `ScanResult.hasAccessDeniedEntries(in:)` expose access failures. Consumers own sorting, filters, and selection.
- **Depth:** root is level 0. `maximumDepth: 1` lists immediate entries; `nil` (the default) is unlimited. `rootDepthLimits` overrides individual roots. Overlapping explicit scopes share traversal and accounting.
- **Incomplete scans:** skipped boundary folders are `.depthLimited`, with unknown contents and zero accounted bytes. Ancestors are `.partial`. Permission failures, cloud-only folders, and excluded mounts also remain visible through item status. Require complete folder scans before offering cleanup.
- **Progress:** coalesced at most ten times per second. `result()` reliably returns completion or throws. Use `currentResult()` sparingly for a queryable intermediate snapshot.

## Savings and ownership

```swift
let selection = result.children(of: result.rootIDs[0]).map(\.id)
let estimate = try await SavingsEstimator.estimate(selection: selection, in: result)
print(estimate.estimatedReclaimableBytes, estimate.isComplete, estimate.limitations)
```

Use `SavingsEstimator` to estimate the bytes reclaimable from selected items. Moving files to Trash does not immediately free space.

The package never deletes files, runs developer tools, grants permissions, or persists results. Xcodes owns confirmations, active-use checks, fresh target validation, Trash/`simctl` operations, and its presentation cache. Cached app results are not authority for cleanup.

## How scanning works

Dedicated, bounded dispatch workers walk depth-first using `getattrlistbulk`, reusable 32 KB buffers, and descriptor-relative `openat`. Known cleanup locations receive priority; bulk metadata avoids a separate syscall for every file. The default worker count favors performance cores when available and can be overridden.

The scanner bounds-checks unaligned records, budgets open descriptors, deduplicates hard links, avoids following symlinks, skips dataless folders, and restores each thread's cloud-download policy. Unsupported bulk enumeration falls back to metadata listing. Nested mounts are skipped unless explicitly requested.

This is our Swift implementation inspired by [Petal v0.1.0](https://github.com/henrydennis/petal/tree/v0.1.0), with no Rust dependency or vendored core. See [NOTICE](NOTICE) and [LICENSE](LICENSE) for attribution.

## Verification

```sh
swift test
swift build -c release
swift run -c release cleanup-benchmark /path/to/folder 10
XCODES_CLEANUP_APFS_TESTS=1 swift test # disposable APFS image tests
```

The benchmark is for verification, not a cleanup CLI. See [performance verification](Documentation/Performance.md) for Petal comparisons and accounting checks.
