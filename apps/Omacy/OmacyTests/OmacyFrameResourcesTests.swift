import XCTest
@testable import Omacy

final class OmacyFrameResourcesTests: XCTestCase {
    func testLateCompletionOnlyReturnsPermitToRetiredGeneration() {
        let retired = OmacyFrameResources()
        let late = try! XCTUnwrap(retired.acquireWritable())
        retired.retire()

        let current = OmacyFrameResources()
        XCTAssertEqual(retired.availablePermitCount, 2)
        XCTAssertEqual(current.availablePermitCount, 3)

        late.complete()

        XCTAssertEqual(retired.availablePermitCount, 3)
        XCTAssertEqual(current.availablePermitCount, 3)
    }

    func testCompletionIsIdempotentAndPoolNeverExceedsThreePermits() {
        let resources = OmacyFrameResources()
        let lease = try! XCTUnwrap(resources.acquireWritable())

        lease.complete()
        lease.complete()

        XCTAssertEqual(resources.availablePermitCount, 3)
        XCTAssertEqual(resources.peakOutstandingCount, 1)
    }

    func testFourthAcquireDropsImmediatelyUntilOneOfThreeFramesCompletes() {
        let resources = OmacyFrameResources()
        let leases = (0..<3).map { _ in resources.acquireWritable()! }
        XCTAssertEqual(resources.availablePermitCount, 0)
        XCTAssertNil(resources.acquireWritable())

        leases[0].complete()
        resources.acquireWritable()?.complete()
        leases.dropFirst().forEach { $0.complete() }

        XCTAssertEqual(resources.availablePermitCount, 3)
        XCTAssertEqual(resources.peakOutstandingCount, 3)
    }

    func testRepeatedRetireAndReplacementStartsEachGenerationFull() {
        var lateCompletions: [OmacyFrameLease] = []

        for _ in 0..<20 {
            let resources = OmacyFrameResources()
            XCTAssertEqual(resources.availablePermitCount, 3)
            lateCompletions.append(resources.acquireWritable()!)
            resources.retire()
        }

        let current = OmacyFrameResources()
        lateCompletions.forEach { $0.complete() }

        XCTAssertEqual(current.availablePermitCount, 3)
    }

    func testWritableRotationNeverReusesSlotWithDelayedReaders() throws {
        let resources = OmacyFrameResources()
        let firstPack = try XCTUnwrap(resources.acquireWritable())
        XCTAssertEqual(firstPack.slot, 0)
        let delayedReuse = try XCTUnwrap(resources.acquireReader(for: firstPack.slot))
        let secondPack = try XCTUnwrap(resources.acquireWritable())
        XCTAssertEqual(secondPack.slot, 1)

        firstPack.complete()
        let thirdPack = try XCTUnwrap(resources.acquireWritable())
        XCTAssertEqual(thirdPack.slot, 2)

        secondPack.complete()
        let fourthPack = try XCTUnwrap(resources.acquireWritable())
        XCTAssertNotEqual(fourthPack.slot, delayedReuse.slot)

        thirdPack.complete()
        fourthPack.complete()
        delayedReuse.complete()
        XCTAssertEqual(resources.availablePermitCount, 3)
    }

    func testLifecycleRepeatedReplaceAndStopRetiresEveryPreviousGeneration() {
        let lifecycle = OmacyFrameResourceLifecycle()

        for _ in 0..<20 {
            let previous = lifecycle.current
            let current = lifecycle.replace()
            XCTAssertTrue(previous?.isRetired ?? true)
            XCTAssertFalse(current.isRetired)
        }

        let last = lifecycle.current
        lifecycle.stop()
        lifecycle.stop()
        XCTAssertTrue(last?.isRetired ?? false)
        XCTAssertNil(lifecycle.current)
    }

    func testConcurrentCompletionsInterleavedWithRetireAndReplaceStayGenerationLocal() {
        let lifecycle = OmacyFrameResourceLifecycle()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "frame-completions", attributes: .concurrent)
        var generations: [OmacyFrameResources] = []

        for generation in 0..<40 {
            let resources = lifecycle.replace()
            generations.append(resources)
            let leases = (0..<3).compactMap { _ in resources.acquireWritable() }
            XCTAssertEqual(leases.count, 3)
            for (index, lease) in leases.enumerated() {
                group.enter()
                queue.asyncAfter(deadline: .now() + .milliseconds((generation + index) % 4)) {
                    lease.complete()
                    group.leave()
                }
            }
        }
        lifecycle.stop()

        XCTAssertEqual(group.wait(timeout: .now() + 3), .success, "bounded completions must not deadlock")
        for resources in generations {
            XCTAssertTrue(resources.isRetired)
            XCTAssertEqual(resources.availablePermitCount, 3)
            XCTAssertLessThanOrEqual(resources.peakOutstandingCount, 3)
        }
    }
}
