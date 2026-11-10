import Darwin
import Foundation

private struct DirectoryJob: Sendable {
    let index: Int
    let path: FilesystemPath
    let parent: DirectoryHandle?
    let name: [UInt8]?
    let rootDevice: UInt64
    let identity: FileIdentity
    let hotspot: Bool
}

/// Every mutable field is protected by condition. Blocking work runs on a dedicated bounded pool.
final class ScanCoordinator: @unchecked Sendable {
    private let condition = WorkerCondition()
    private let id: UUID
    private let request: ScanRequest
    private let continuation: AsyncStream<ScanSnapshot>.Continuation
    private var nodes: [StoredNode] = []
    private var roots: [Int] = []
    private let traversalScopes: [(path: FilesystemPath, levels: Int, limit: Int?)]
    private let descriptorBudget: Int
    private var high: [DirectoryJob] = []
    private var low: [DirectoryJob] = []
    private var pending = 0
    private var activeHotspots = 0
    private var cancelled = false
    private var terminal: Result<ScanResult, any Error>?
    private var failure: (any Error)?
    private var waiters: [CheckedContinuation<ScanResult, any Error>] = []
    private var hardlinks: Set<FileIdentity> = []
    private var enumerated: Set<Int> = []
    private var remainingChildren: [Int: Int] = [:]
    private var incompleteNodes: Set<Int> = []
    private var files: UInt64 = 0
    private var directories: UInt64 = 0
    private var bytes: UInt64 = 0
    private var errors: UInt64 = 0
    private var cloudOnly: UInt64 = 0
    private var excluded: UInt64 = 0
    private let started = ContinuousClock.now
    private var firstFindingNanoseconds: UInt64?
    private var publishedFirstFinding = false
    private var catalogNodes: Set<Int> = []
    private var lastPublication = ContinuousClock.now

    init(id: UUID, request: ScanRequest, continuation: AsyncStream<ScanSnapshot>.Continuation) {
        self.id = id; self.request = request; self.continuation = continuation
        traversalScopes = request.roots.map { root in
            (root, root.bytes.split(separator: 47).count, request.rootDepthLimits[root] ?? request.maximumDepth)
        }
        var limit = rlimit()
        if getrlimit(RLIMIT_NOFILE, &limit) == 0 {
            descriptorBudget = Int(min(2048, limit.rlim_cur > 128 ? limit.rlim_cur - 128 : 0))
        } else { descriptorBudget = 64 }
    }

    func start() {
        let queue = DispatchQueue(label: "org.xcodes.cleanup.scan.\(id)", qos: .userInitiated, attributes: .concurrent)
        queue.async { [self] in
            do {
                try withoutCloudDownloads { try initialize() }
            } catch { condition.lock(); failure = error; condition.unlock(); finish(); return }
            let group = DispatchGroup()
            for _ in 0..<request.workerCount {
                group.enter()
                queue.async { [self] in
                    defer { group.leave() }
                    do {
                        try withoutCloudDownloads {
                            let reader = DirectoryReader()
                            while let job = next() { process(job, reader: reader) }
                        }
                    } catch {
                        condition.lock(); failure = error; cancelled = true; condition.broadcast(); condition.unlock()
                    }
                }
            }
            group.notify(queue: queue) { [self] in finish() }
        }
    }

    private func initialize() throws {
        let reader = DirectoryReader()
        var unique: [(path: FilesystemPath, metadata: Result<DirectoryEntry, any Error>)] = []
        for root in request.roots.sorted(by: { $0.bytes.count < $1.bytes.count }) {
            let metadata = Result { try reader.metadata(root) }
            let device = try? metadata.get().identity.device
            // Explicit roots on another mounted filesystem must survive ancestor normalization.
            if unique.contains(where: { candidate in
                candidate.path == root || (candidate.path.contains(root) && (try? candidate.metadata.get().identity.device) == device)
            }) { continue }
            unique.append((root, metadata))
        }
        condition.lock()
        defer { condition.unlock() }
        for (root, metadata) in unique {
            let index = nodes.count
            roots.append(index)
            if request.categories.contains(where: { $0.location == root }) { catalogNodes.insert(index) }
            do {
                let entry = try metadata.get()
                var node = StoredNode(name: entry.name, parent: nil, rootPath: root, kind: entry.kind,
                                      identity: entry.identity, allocatedBytes: entry.allocatedBytes, status: .complete)
                if entry.isCloudOnly { node.status = .cloudOnly; cloudOnly += 1 }
                else if entry.kind == .directory {
                    node.status = .scanning
                    let hotspot = isHotspot(root)
                    enqueue(DirectoryJob(index: index, path: root, parent: nil, name: nil, rootDevice: entry.identity.device, identity: entry.identity, hotspot: hotspot))
                } else {
                    files += 1
                    if entry.links > 1, !hardlinks.insert(entry.identity).inserted { node.allocatedBytes = 0 }
                }
                bytes += node.allocatedBytes
                nodes.append(node)
                recordFirstFinding(index)
            } catch {
                let code = (error as? ScanError).flatMap { if case .system(let code) = $0 { code } else { nil } }
                nodes.append(StoredNode(name: [], parent: nil, rootPath: root, kind: .directory,
                    identity: FileIdentity(device: 0, inode: 0), allocatedBytes: 0, status: .inaccessible, errorCode: code))
                errors += 1
            }
        }
    }

    private func canEnumerate(_ path: FilesystemPath) -> Bool {
        if request.maximumDepth == nil && request.rootDepthLimits.isEmpty { return true }
        let levels = path.bytes.split(separator: 47).count
        return traversalScopes.contains { scope in
            if scope.path.contains(path) {
                return scope.limit.map { levels - scope.levels < $0 } ?? true
            }
            // Reach explicitly requested deeper roots even beyond another root's limit.
            return path.contains(scope.path)
        }
    }

    private func isHotspot(_ path: FilesystemPath) -> Bool {
        request.categories.contains { $0.location.contains(path) || path.contains($0.location) }
    }

    private func enqueue(_ job: DirectoryJob) {
        if job.hotspot { high.append(job) } else { low.append(job) }
        pending += 1
    }

    private func next() -> DirectoryJob? {
        condition.lock()
        defer { condition.unlock() }
        while !cancelled {
            if let job = high.popLast() { activeHotspots += 1; return job }
            // Give known locations their head start rather than competing with the general walk.
            if activeHotspots == 0, let job = low.popLast() { return job }
            if pending == 0 { return nil }
            condition.wait()
        }
        return nil
    }

    private func isCancelled() -> Bool { condition.lock(); defer { condition.unlock() }; return cancelled }

    private func process(_ job: DirectoryJob, reader: DirectoryReader) {
        var listing: DirectoryListing?
        var directory: DirectoryHandle?
        var error: (any Error)?
        do {
            // Reject replaced directories even when descriptor-relative opening succeeds.
            directory = try reader.open(job.path, parent: job.parent, name: job.name, expectedIdentity: job.identity)
            listing = try reader.list(directory!, cancelled: isCancelled)
        } catch let caught { error = caught }
        condition.lock()
        defer { condition.unlock() }
        if job.hotspot { activeHotspots -= 1 }
        pending -= 1
        directories += 1
        if cancelled { condition.broadcast(); return }
        enumerated.insert(job.index)
        if let listing {
            errors += listing.errors
            if listing.errors > 0 { incompleteNodes.insert(job.index) }
            // Retain a bounded number of parent descriptors; full-path opening is the fallback.
            let retain = DirectoryHandle.liveCount < descriptorBudget
            for entry in listing.entries {
                let index = nodes.count
                var node = StoredNode(name: entry.name, parent: job.index, kind: entry.kind, identity: entry.identity,
                                      allocatedBytes: entry.allocatedBytes, status: .complete)
                if entry.kind == .directory {
                    let path = job.path.appending(entry.name)
                    if entry.isCloudOnly { node.status = .cloudOnly; cloudOnly += 1 }
                    else if entry.isMount || entry.identity.device != job.rootDevice { node.status = .mountExcluded; excluded += 1; node.allocatedBytes = 0 }
                    else if !canEnumerate(path) {
                        node.status = .depthLimited
                        node.allocatedBytes = 0
                    }
                    else {
                        node.status = .scanning
                        remainingChildren[job.index, default: 0] += 1
                        if request.categories.contains(where: { $0.location == path }) { catalogNodes.insert(index) }
                        enqueue(DirectoryJob(index: index, path: path, parent: retain ? directory : nil,
                                             name: entry.name, rootDevice: job.rootDevice, identity: entry.identity, hotspot: isHotspot(path)))
                    }
                } else {
                    files += 1
                    if entry.links > 1, !hardlinks.insert(entry.identity).inserted { node.allocatedBytes = 0 }
                }
                bytes += node.allocatedBytes
                nodes.append(node)
                nodes[job.index].children.append(index)
            }
        } else {
            nodes[job.index].status = .inaccessible
            if case .system(let code) = error as? ScanError { nodes[job.index].errorCode = code }
            errors += 1
        }
        finalizeAncestors(job.index)
        if (firstFindingNanoseconds != nil && !publishedFirstFinding) || ContinuousClock.now - lastPublication >= .milliseconds(100) {
            if firstFindingNanoseconds != nil { publishedFirstFinding = true }
            lastPublication = .now
            continuation.yield(ScanSnapshot(scanID: id, progress: progress(), findings: findings(), result: nil))
        }
        if pending == 0 || !high.isEmpty || (activeHotspots == 0 && !low.isEmpty) { condition.broadcast() }
    }

    // Finalize each folder once its children finish; skipped children make the total partial.
    private func finalizeAncestors(_ start: Int) {
        var current: Int? = start
        while let index = current {
            guard enumerated.contains(index), remainingChildren[index, default: 0] == 0 else { break }
            if nodes[index].status == .scanning { nodes[index].status = incompleteNodes.contains(index) ? .partial : .complete }
            for child in nodes[index].children {
                nodes[index].allocatedBytes += nodes[child].allocatedBytes
                nodes[index].containedItemCount += 1 + nodes[child].containedItemCount
                if nodes[child].status != .complete, nodes[index].status == .complete { nodes[index].status = .partial }
            }
            recordFirstFinding(index)
            enumerated.remove(index)
            current = nodes[index].parent
            if let parent = current { remainingChildren[parent, default: 0] -= 1 }
        }
    }

    private func recordFirstFinding(_ index: Int) {
        guard firstFindingNanoseconds == nil, catalogNodes.contains(index), nodes[index].status == .complete, nodes[index].allocatedBytes > 0 else { return }
        let elapsed = started.duration(to: .now).components
        firstFindingNanoseconds = UInt64(max(0, elapsed.seconds)) * 1_000_000_000 + UInt64(max(0, elapsed.attoseconds / 1_000_000_000))
    }

    private func progress(phase: ScanPhase? = nil) -> ScanProgress {
        ScanProgress(phase: phase ?? ((!high.isEmpty || activeHotspots > 0) ? .hotspots : .scanning),
            scannedFileCount: files, scannedDirectoryCount: directories, allocatedBytes: bytes,
            inaccessibleCount: errors, cloudOnlyCount: cloudOnly, mountExcludedCount: excluded, firstFindingElapsedNanoseconds: firstFindingNanoseconds)
    }

    private func findings() -> [CleanupFinding] {
        guard !request.categories.isEmpty else { return [] }
        // Traverse components, not every file, for fixed catalog locations.
        let result = ScanResult(scanID: id, rootIDs: roots.map { ScanItemID(scanID: id, index: $0) }, findings: [], progress: progress(), nodes: nodes)
        var findings: [CleanupFinding] = []
        for category in request.categories {
            guard let item = result.item(at: category.location), item.allocatedBytes > 0, item.status != .scanning else { continue }
            findings.append(CleanupFinding(id: category.id, categoryID: category.id, title: category.title,
                explanation: category.explanation, classification: category.classification, itemIDs: [item.id],
                allocatedBytes: item.allocatedBytes, isComplete: item.status == .complete))
        }
        return findings
    }

    private func completedFindings() -> [CleanupFinding] {
        var output = findings()
        guard request.detectNodeModules else { return output }
        let result = ScanResult(scanID: id, rootIDs: roots.map { ScanItemID(scanID: id, index: $0) }, findings: [], progress: progress(), nodes: nodes)
        var stack = roots
        var modules: [Int] = []
        while let index = stack.popLast() {
            if nodes[index].kind == .directory, nodes[index].name == Array("node_modules".utf8) { modules.append(index) }
            else { stack.append(contentsOf: nodes[index].children.filter { nodes[$0].kind == .directory }) }
        }
        if !modules.isEmpty {
            output.append(CleanupFinding(id: "nodeModules", categoryID: "nodeModules", title: "node_modules",
                explanation: "Dependencies can be reinstalled with the project's package manager. Review local changes first.",
                classification: .review, itemIDs: modules.map(result.makeID),
                allocatedBytes: modules.reduce(0) { $0 + nodes[$1].allocatedBytes }, isComplete: modules.allSatisfy { nodes[$0].status == .complete }))
        }
        return output
    }

    private func finish() {
        condition.lock()
        if cancelled { high.removeAll(); low.removeAll() }
        let phase: ScanPhase = failure != nil ? .failed : cancelled ? .cancelled : .completed
        let result = ScanResult(scanID: id, rootIDs: roots.map { ScanItemID(scanID: id, index: $0) },
                                findings: cancelled ? findings() : completedFindings(), progress: progress(phase: phase), nodes: nodes)
        let outcome: Result<ScanResult, any Error> = failure.map { .failure($0) } ?? (cancelled ? .failure(CancellationError()) : .success(result))
        terminal = outcome
        let waiting = waiters
        waiters.removeAll()
        condition.unlock()
        continuation.yield(ScanSnapshot(scanID: id, progress: result.progress, findings: result.findings, result: result))
        continuation.finish()
        continuation.onTermination = nil
        for waiter in waiting { waiter.resume(with: outcome) }
    }

    func wait(_ waiter: CheckedContinuation<ScanResult, any Error>) {
        condition.lock()
        if let terminal { condition.unlock(); waiter.resume(with: terminal) }
        else { waiters.append(waiter); condition.unlock() }
    }

    func cancel() { condition.lock(); if terminal == nil { cancelled = true }; condition.broadcast(); condition.unlock() }

    func snapshotResult() -> ScanResult {
        condition.lock()
        defer { condition.unlock() }
        if case .success(let completed)? = terminal { return completed }
        return ScanResult(scanID: id, rootIDs: roots.map { ScanItemID(scanID: id, index: $0) }, findings: findings(),
                          progress: progress(phase: terminal == nil ? nil : failure != nil ? .failed : cancelled ? .cancelled : .completed), nodes: nodes)
    }
}
