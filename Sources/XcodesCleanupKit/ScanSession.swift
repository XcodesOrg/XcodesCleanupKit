import Foundation

/// A single-consumer progress stream plus independently awaitable completion.
/// All shared mutable state lives in the lock-protected coordinator.
public final class ScanSession: Sendable {
    public let id: UUID
    public let snapshots: AsyncStream<ScanSnapshot>
    private let coordinator: ScanCoordinator

    public init(request: ScanRequest) throws {
        guard !request.roots.isEmpty else { throw ScanError.noRoots }
        guard (1...64).contains(request.workerCount) else { throw ScanError.invalidWorkerCount }
        guard request.maximumDepth.map({ $0 >= 1 }) ?? true,
              request.rootDepthLimits.values.allSatisfy({ $0 >= 1 }),
              request.rootDepthLimits.keys.allSatisfy({ request.roots.contains($0) }) else { throw ScanError.invalidDepth }
        let id = UUID()
        self.id = id
        let (stream, continuation) = AsyncStream.makeStream(of: ScanSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        self.snapshots = stream
        coordinator = ScanCoordinator(id: id, request: request, continuation: continuation)
        continuation.onTermination = { [coordinator] reason in
            if case .cancelled = reason { coordinator.cancel() }
        }
        coordinator.start()
    }

    deinit { coordinator.cancel() }

    public func cancel() { coordinator.cancel() }

    public func result() async throws -> ScanResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { coordinator.wait($0) }
        } onCancel: { coordinator.cancel() }
    }

    /// An immutable view of the currently discovered hierarchy; avoid calling on every UI frame.
    public func currentResult() -> ScanResult { coordinator.snapshotResult() }
}
