import Foundation
import os

/// An unfair lock for the hot path; sleeping workers each have their own wakeup token.
/// The caller holds the lock when calling wait or broadcast, just as with NSCondition.
final class WorkerCondition: @unchecked Sendable {
    private let mutex = OSAllocatedUnfairLock()
    private var sleepers: [DispatchSemaphore] = []

    func lock() { mutex.lock() }
    func unlock() { mutex.unlock() }

    func wait() {
        let wakeup = DispatchSemaphore(value: 0)
        sleepers.append(wakeup)
        mutex.unlock()
        wakeup.wait()
        mutex.lock()
    }

    func broadcast() {
        let waiting = sleepers
        sleepers.removeAll(keepingCapacity: true)
        for wakeup in waiting { wakeup.signal() }
    }
}
