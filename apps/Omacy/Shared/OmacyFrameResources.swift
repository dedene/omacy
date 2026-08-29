import Foundation
import Metal

/// Buffers and GPU-read permits belonging to one renderer attachment.
final class OmacyFrameResources: @unchecked Sendable {
    private static let frameCount = 3

    private let semaphore = DispatchSemaphore(value: frameCount)
    private let lock = NSLock()
    private var outstandingCount = 0
    private var peakCount = 0
    private var retired = false
    private var nextWritableSlot = 0
    private var readers = Array(repeating: 0, count: frameCount)
    private var buffers: [MTLBuffer?] = Array(repeating: nil, count: frameCount)

    var availablePermitCount: Int { lock.withLock { Self.frameCount - outstandingCount } }
    var peakOutstandingCount: Int { lock.withLock { peakCount } }
    var isRetired: Bool { lock.withLock { retired } }

    func acquireWritable() -> OmacyFrameLease? {
        guard semaphore.wait(timeout: .now()) == .success else { return nil }
        return lock.withLock {
            guard !retired else {
                semaphore.signal()
                return nil
            }
            for offset in 0..<Self.frameCount {
                let slot = (nextWritableSlot + offset) % Self.frameCount
                if readers[slot] == 0 {
                    nextWritableSlot = (slot + 1) % Self.frameCount
                    return makeLease(slot: slot)
                }
            }
            assertionFailure("frame permit acquired without a writable slot")
            semaphore.signal()
            return nil
        }
    }

    func acquireReader(for slot: Int) -> OmacyFrameLease? {
        guard (0..<Self.frameCount).contains(slot),
              semaphore.wait(timeout: .now()) == .success else { return nil }
        return lock.withLock {
            guard !retired else {
                semaphore.signal()
                return nil
            }
            return makeLease(slot: slot)
        }
    }

    func buffer(for lease: OmacyFrameLease, device: MTLDevice, minimumLength: Int) -> MTLBuffer? {
        precondition(lease.resources === self)
        return lock.withLock {
            if buffers[lease.slot] == nil || buffers[lease.slot]!.length < minimumLength {
                buffers[lease.slot] = device.makeBuffer(
                    length: max(minimumLength, 4096),
                    options: .storageModeShared
                )
            }
            return buffers[lease.slot]
        }
    }

    func buffer(for lease: OmacyFrameLease) -> MTLBuffer? {
        precondition(lease.resources === self)
        return lock.withLock { buffers[lease.slot] }
    }

    func retire() {
        lock.withLock { retired = true }
    }

    private func makeLease(slot: Int) -> OmacyFrameLease {
        readers[slot] += 1
        outstandingCount += 1
        peakCount = max(peakCount, outstandingCount)
        return OmacyFrameLease(resources: self, slot: slot)
    }

    fileprivate func complete(slot: Int) {
        lock.withLock {
            precondition(outstandingCount > 0 && readers[slot] > 0)
            readers[slot] -= 1
            outstandingCount -= 1
        }
        semaphore.signal()
    }
}

final class OmacyFrameLease: @unchecked Sendable {
    fileprivate let resources: OmacyFrameResources
    let slot: Int
    private let lock = NSLock()
    private var completed = false

    fileprivate init(resources: OmacyFrameResources, slot: Int) {
        self.resources = resources
        self.slot = slot
    }

    func complete() {
        let shouldComplete = lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
        if shouldComplete { resources.complete(slot: slot) }
    }

    deinit { complete() }
}

final class OmacyFrameResourceLifecycle {
    private(set) var current: OmacyFrameResources?

    @discardableResult
    func replace() -> OmacyFrameResources {
        stop()
        let resources = OmacyFrameResources()
        current = resources
        return resources
    }

    func stop() {
        current?.retire()
        current = nil
    }
}
