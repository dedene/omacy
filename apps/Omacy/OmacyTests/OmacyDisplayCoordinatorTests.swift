import XCTest
@testable import Omacy

@MainActor
final class OmacyDisplayCoordinatorTests: XCTestCase {
    private var mockTime: TimeInterval = 0.0

    private func makeCoordinator(
        dwellDuration: TimeInterval = 1.5,
        maxBarrierWait: TimeInterval = 10.0,
        startBarrierTimeout: TimeInterval = 0.5,
        expectedParticipants: (() -> Int)? = { 1 },
        shuffler: @escaping ([String]) -> [String] = { $0 },
        seedGenerator: @escaping () -> UInt64 = { 42 }
    ) -> OmacyDisplayCoordinator {
        mockTime = 0.0
        let config = OmacyDisplayCoordinator.Configuration(
            dwellDuration: dwellDuration,
            maxBarrierWait: maxBarrierWait,
            startBarrierTimeout: startBarrierTimeout,
            expectedParticipants: expectedParticipants,
            clock: { [weak self] in self?.mockTime ?? 0.0 },
            shuffler: shuffler,
            seedGenerator: seedGenerator
        )
        return OmacyDisplayCoordinator(configuration: config)
    }

    func testSingleDisplayRunsAndDwellsBeforeAdvancing() {
        let coordinator = makeCoordinator(dwellDuration: 1.5, shuffler: { $0 })
        let p1 = coordinator.registerParticipant()

        let plan = coordinator.initialPlan(for: p1, availableEffects: ["matrix", "beams"])
        XCTAssertEqual(plan.effect, "matrix")
        XCTAssertEqual(coordinator.currentCycle, 0)

        // P1 finishes cycle 0 at t=0
        mockTime = 0.0
        let decision1 = coordinator.evaluateBoundary(for: p1, cycle: 0, availableEffects: ["matrix", "beams"])
        XCTAssertEqual(decision1, .wait)

        // At t=1.0, still dwelling (dwellDuration is 1.5)
        mockTime = 1.0
        let decision2 = coordinator.evaluateBoundary(for: p1, cycle: 0, availableEffects: ["matrix", "beams"])
        XCTAssertEqual(decision2, .wait)

        // At t=1.5, dwell completed -> proposes cycle 1
        mockTime = 1.5
        let decision3 = coordinator.evaluateBoundary(for: p1, cycle: 0, availableEffects: ["matrix", "beams"])
        guard case .proceed(let nextPlan) = decision3 else {
            return XCTFail("Expected proceed after dwell")
        }
        XCTAssertEqual(nextPlan.cycle, 1)
        XCTAssertEqual(nextPlan.effect, "beams")
        // Transactional: coordinator currentCycle is still 0 until committed
        XCTAssertEqual(coordinator.currentCycle, 0)

        coordinator.commitAdvancement(for: p1, cycle: 1)
        XCTAssertEqual(coordinator.currentCycle, 1)
    }

    func testMultipleDisplaysFastWaitsForSlowThenBothAdvanceTogether() {
        let coordinator = makeCoordinator(dwellDuration: 1.5, expectedParticipants: { 2 }, shuffler: { $0 })
        let p1 = coordinator.registerParticipant()
        let p2 = coordinator.registerParticipant()

        let plan1 = coordinator.initialPlan(for: p1, availableEffects: ["matrix", "beams"])
        let plan2 = coordinator.initialPlan(for: p2, availableEffects: ["matrix", "beams"])
        XCTAssertEqual(plan1.effect, "matrix")
        XCTAssertEqual(plan2.effect, "matrix", "Both displays must share the exact initial effect")
        XCTAssertEqual(plan1.seed, plan2.seed, "Both displays must share the exact initial seed")

        // Fast display P1 finishes at t=1.0
        mockTime = 1.0
        XCTAssertEqual(coordinator.evaluateBoundary(for: p1, cycle: 0, availableEffects: ["matrix", "beams"]), .wait)

        // P1 keeps checking at t=2.0 while P2 is still animating
        mockTime = 2.0
        XCTAssertEqual(coordinator.evaluateBoundary(for: p1, cycle: 0, availableEffects: ["matrix", "beams"]), .wait)

        // Slow display P2 finishes at t=3.0 -> now both finished, dwell begins at t=3.0
        mockTime = 3.0
        XCTAssertEqual(coordinator.evaluateBoundary(for: p2, cycle: 0, availableEffects: ["matrix", "beams"]), .wait)

        // Mid-dwell check at t=4.0 (dwell duration 1.5s ends at 4.5s)
        mockTime = 4.0
        XCTAssertEqual(coordinator.evaluateBoundary(for: p1, cycle: 0, availableEffects: ["matrix", "beams"]), .wait)
        XCTAssertEqual(coordinator.evaluateBoundary(for: p2, cycle: 0, availableEffects: ["matrix", "beams"]), .wait)

        // At t=4.5, dwell elapses -> P1 receives proposal
        mockTime = 4.5
        let p1Advance = coordinator.evaluateBoundary(for: p1, cycle: 0, availableEffects: ["matrix", "beams"])
        guard case .proceed(let p1Plan) = p1Advance else { return XCTFail("Expected proceed for P1") }
        XCTAssertEqual(p1Plan.cycle, 1)
        XCTAssertEqual(p1Plan.effect, "beams")

        // P1 commits, but P2 hasn't committed yet
        coordinator.commitAdvancement(for: p1, cycle: 1)
        XCTAssertEqual(coordinator.currentCycle, 0, "currentCycle must remain 0 until all participants commit")

        // P2 checks on next tick (still at cycle 0) -> receives same cycle 1 proposal
        mockTime = 4.51
        let p2Advance = coordinator.evaluateBoundary(for: p2, cycle: 0, availableEffects: ["matrix", "beams"])
        guard case .proceed(let p2Plan) = p2Advance else { return XCTFail("Expected proceed for P2") }
        XCTAssertEqual(p2Plan.cycle, 1)
        XCTAssertEqual(p2Plan.effect, "beams")
        XCTAssertEqual(p2Plan.seed, p1Plan.seed, "Both participants must receive the exact same seed")

        // P2 commits -> now all participants committed, coordinator currentCycle becomes 1
        coordinator.commitAdvancement(for: p2, cycle: 1)
        XCTAssertEqual(coordinator.currentCycle, 1)
    }

    func testCycleSeedsDeriveFromOneGroupSeed() {
        var generatedSeeds: [UInt64] = [500, 900, 1_300]
        var generatorCalls = 0
        let coordinator = makeCoordinator(
            dwellDuration: 0.0,
            shuffler: { $0 },
            seedGenerator: {
                generatorCalls += 1
                return generatedSeeds.removeFirst()
            }
        )
        let participant = coordinator.registerParticipant()

        let initial = coordinator.initialPlan(for: participant, availableEffects: ["matrix", "beams"])
        XCTAssertEqual(initial.seed, 500)

        guard case .proceed(let cycle1) = coordinator.evaluateBoundary(
            for: participant,
            cycle: 0,
            availableEffects: ["matrix", "beams"]
        ) else {
            return XCTFail("Expected cycle 1 proposal")
        }
        XCTAssertEqual(cycle1.seed, 501)
        coordinator.commitAdvancement(for: participant, cycle: cycle1.cycle)

        guard case .proceed(let cycle2) = coordinator.evaluateBoundary(
            for: participant,
            cycle: 1,
            availableEffects: ["matrix", "beams"]
        ) else {
            return XCTFail("Expected cycle 2 proposal")
        }
        XCTAssertEqual(cycle2.seed, 502)
        XCTAssertEqual(generatorCalls, 1)
    }

    func testFailedParticipantDoesNotAdvanceCoordinatorAndAllowsRetry() {
        let coordinator = makeCoordinator(dwellDuration: 1.0, expectedParticipants: { 2 }, shuffler: { $0 })
        let p1 = coordinator.registerParticipant()
        let p2 = coordinator.registerParticipant()
        _ = coordinator.initialPlan(for: p1, availableEffects: ["matrix", "beams"])
        _ = coordinator.initialPlan(for: p2, availableEffects: ["matrix", "beams"])

        // Both finish cycle 0 at t=1.0
        mockTime = 1.0
        _ = coordinator.evaluateBoundary(for: p1, cycle: 0, availableEffects: ["matrix", "beams"])
        _ = coordinator.evaluateBoundary(for: p2, cycle: 0, availableEffects: ["matrix", "beams"])

        // Dwell finishes at t=2.0
        mockTime = 2.0
        let p1Decision = coordinator.evaluateBoundary(for: p1, cycle: 0, availableEffects: ["matrix", "beams"])
        guard case .proceed(let proposal) = p1Decision else { return XCTFail("Expected proceed") }
        // P1 succeeds and commits
        coordinator.commitAdvancement(for: p1, cycle: proposal.cycle)

        // P2 queries boundary
        let p2Decision1 = coordinator.evaluateBoundary(for: p2, cycle: 0, availableEffects: ["matrix", "beams"])
        XCTAssertEqual(p2Decision1, .proceed(proposal))

        // Suppose P2 transition fails! P2 does NOT commit advancement.
        // Coordinator must not finalize cycle 1.
        XCTAssertEqual(coordinator.currentCycle, 0)

        // On next tick, P2 retries evaluateBoundary at cycle 0
        mockTime = 2.05
        let p2Retry = coordinator.evaluateBoundary(for: p2, cycle: 0, availableEffects: ["matrix", "beams"])
        XCTAssertEqual(p2Retry, .proceed(proposal), "Must receive the same proposed cycle and effect to retry")

        // P2 retry succeeds and commits
        coordinator.commitAdvancement(for: p2, cycle: proposal.cycle)
        XCTAssertEqual(coordinator.currentCycle, 1)
    }

    func testStartBarrierHoldsUntilAllExpectedParticipantsRegister() {
        let coordinator = makeCoordinator(startBarrierTimeout: 1.0, expectedParticipants: { 2 })

        // P1 registers at t=0
        mockTime = 0.0
        let p1 = coordinator.registerParticipant()
        let plan1 = coordinator.initialPlan(for: p1, availableEffects: ["matrix"])
        XCTAssertNil(plan1.startEpoch, "Start barrier must not be released with only 1 of 2 participants registered")
        XCTAssertNil(coordinator.startEpoch(for: 0))

        // P1 checks startEpoch before P2 arrives
        mockTime = 0.2
        XCTAssertNil(coordinator.startEpoch(for: 0))

        // P2 registers at t=0.3
        mockTime = 0.3
        let p2 = coordinator.registerParticipant()
        let plan2 = coordinator.initialPlan(for: p2, availableEffects: ["matrix"])
        XCTAssertEqual(plan2.startEpoch, 0.3, "Start barrier must be released as soon as 2nd participant registers")
        XCTAssertEqual(coordinator.startEpoch(for: 0), 0.3)
    }

    func testStartBarrierReleasesAfterTimeoutIfSecondParticipantNeverRegisters() {
        let coordinator = makeCoordinator(startBarrierTimeout: 1.0, expectedParticipants: { 2 })

        mockTime = 0.0
        let p1 = coordinator.registerParticipant()
        _ = coordinator.initialPlan(for: p1, availableEffects: ["matrix"])
        XCTAssertNil(coordinator.startEpoch(for: 0))

        // Mid-timeout check
        mockTime = 0.5
        XCTAssertNil(coordinator.startEpoch(for: 0))

        // Timeout reached at t=1.0
        mockTime = 1.0
        XCTAssertEqual(coordinator.startEpoch(for: 0), 1.0, "Start barrier must release after timeout")
    }

    func testUnregisteringSlowDisplayReleasesBarrierForWaitingDisplay() {
        let coordinator = makeCoordinator(dwellDuration: 1.0, expectedParticipants: { 2 })
        let p1 = coordinator.registerParticipant()
        let p2 = coordinator.registerParticipant()

        _ = coordinator.initialPlan(for: p1, availableEffects: ["wipe", "fade"])
        _ = coordinator.initialPlan(for: p2, availableEffects: ["wipe", "fade"])

        // P1 finishes at t=1.0
        mockTime = 1.0
        XCTAssertEqual(coordinator.evaluateBoundary(for: p1, cycle: 0, availableEffects: ["wipe", "fade"]), .wait)

        // P2 disconnects at t=2.0
        mockTime = 2.0
        coordinator.unregisterParticipant(id: p2)

        // At t=2.5, still in dwell (dwell started at t=2.0 when P2 was removed)
        mockTime = 2.5
        XCTAssertEqual(coordinator.evaluateBoundary(for: p1, cycle: 0, availableEffects: ["wipe", "fade"]), .wait)

        // At t=3.0 (1.0s after P2 disconnected), dwell completes
        mockTime = 3.0
        let decision = coordinator.evaluateBoundary(for: p1, cycle: 0, availableEffects: ["wipe", "fade"])
        guard case .proceed(let plan) = decision else {
            return XCTFail("Expected proceed after remaining participant finishes dwell")
        }
        XCTAssertEqual(plan.cycle, 1)
        coordinator.commitAdvancement(for: p1, cycle: 1)
        XCTAssertEqual(coordinator.currentCycle, 1)
    }

    func testSafetyTimeoutAdvancesCycleWhenOneDisplayStalls() {
        let coordinator = makeCoordinator(dwellDuration: 1.0, maxBarrierWait: 5.0, expectedParticipants: { 2 })
        let p1 = coordinator.registerParticipant()
        let p2 = coordinator.registerParticipant()

        _ = coordinator.initialPlan(for: p1, availableEffects: ["wipe", "fade"])
        _ = coordinator.initialPlan(for: p2, availableEffects: ["wipe", "fade"])

        // P1 finishes at t=1.0
        mockTime = 1.0
        XCTAssertEqual(coordinator.evaluateBoundary(for: p1, cycle: 0, availableEffects: ["wipe", "fade"]), .wait)

        // P2 stalls and never finishes. Time advances past 5.0s timeout (t=6.1)
        mockTime = 6.1
        let timeoutDecision = coordinator.evaluateBoundary(for: p1, cycle: 0, availableEffects: ["wipe", "fade"])
        guard case .proceed(let plan) = timeoutDecision else {
            return XCTFail("Expected safety timeout to release waiting participant")
        }
        XCTAssertEqual(plan.cycle, 1)
        coordinator.commitAdvancement(for: p1, cycle: 1)
        XCTAssertEqual(coordinator.currentCycle, 1)
        XCTAssertEqual(coordinator.activeParticipantCount, 1)
        XCTAssertEqual(coordinator.startEpoch(for: 1), 6.1)

        // Later at t=8.0, P2 finally finishes its cycle 0
        mockTime = 8.0
        let p2Catchup = coordinator.evaluateBoundary(for: p2, cycle: 0, availableEffects: ["wipe", "fade"])
        guard case .proceed(let p2Plan) = p2Catchup else { return XCTFail("Expected catchup proceed") }
        XCTAssertEqual(p2Plan.cycle, 1)
        XCTAssertEqual(p2Plan.effect, plan.effect)
        XCTAssertEqual(p2Plan.seed, plan.seed)
    }

    func testShuffleAvoidsConsecutiveRepeatsAcrossPool() {
        let pool = ["matrix", "beams", "wipe"]
        let coordinator = makeCoordinator(dwellDuration: 0.0, shuffler: { $0 })
        let p1 = coordinator.registerParticipant()

        var sequence: [String] = []
        let current = coordinator.initialPlan(for: p1, availableEffects: pool)
        sequence.append(current.effect)

        for _ in 0..<10 {
            mockTime += 1.0
            let decision = coordinator.evaluateBoundary(for: p1, cycle: coordinator.currentCycle, availableEffects: pool)
            guard case .proceed(let next) = decision else {
                return XCTFail("Expected immediate proceed with dwellDuration = 0")
            }
            coordinator.commitAdvancement(for: p1, cycle: next.cycle)
            sequence.append(next.effect)
        }

        // Verify no two adjacent effects are identical
        for i in 0..<(sequence.count - 1) {
            XCTAssertNotEqual(sequence[i], sequence[i + 1], "Effects at index \(i) and \(i + 1) must not repeat consecutively: \(sequence)")
        }
    }

    func testSingleItemPoolAlwaysReturnsSingleEffect() {
        let pool = ["wipe"]
        let coordinator = makeCoordinator(dwellDuration: 0.0)
        let p1 = coordinator.registerParticipant()

        XCTAssertEqual(coordinator.initialPlan(for: p1, availableEffects: pool).effect, "wipe")

        for _ in 0..<5 {
            mockTime += 1.0
            let decision = coordinator.evaluateBoundary(for: p1, cycle: coordinator.currentCycle, availableEffects: pool)
            guard case .proceed(let plan) = decision else { return XCTFail("Expected proceed") }
            XCTAssertEqual(plan.effect, "wipe")
            coordinator.commitAdvancement(for: p1, cycle: plan.cycle)
        }
    }

    func testResetRestoresIdleState() {
        let coordinator = makeCoordinator()
        let p1 = coordinator.registerParticipant()
        _ = coordinator.initialPlan(for: p1, availableEffects: ["wipe"])
        XCTAssertEqual(coordinator.activeParticipantCount, 1)

        coordinator.reset()
        XCTAssertEqual(coordinator.activeParticipantCount, 0)
        XCTAssertEqual(coordinator.currentCycle, 0)
        XCTAssertNil(coordinator.currentEffect)
    }

    func testParticipantWithStaleHigherCycleRecoversAndDoesNotDeadlock() {
        let coordinator = makeCoordinator(dwellDuration: 1.0)
        let p1 = coordinator.registerParticipant()
        _ = coordinator.initialPlan(for: p1, availableEffects: ["matrix", "beams"])
        XCTAssertEqual(coordinator.currentCycle, 0)

        mockTime = 1.0
        let decision = coordinator.evaluateBoundary(for: p1, cycle: 5, availableEffects: ["matrix", "beams"])
        XCTAssertEqual(decision, .wait, "Must participate in current cycle 0 and wait for dwell")

        mockTime = 2.0
        let advance = coordinator.evaluateBoundary(for: p1, cycle: 0, availableEffects: ["matrix", "beams"])
        guard case .proceed(let plan) = advance else { return XCTFail("Expected proceed") }
        XCTAssertEqual(plan.cycle, 1)
        XCTAssertEqual(plan.effect, "beams")
        coordinator.commitAdvancement(for: p1, cycle: 1)
        XCTAssertEqual(coordinator.currentCycle, 1)
    }

    func testLateJoiningParticipantDuringDwellDoesNotInterruptActiveDwell() {
        let coordinator = makeCoordinator(dwellDuration: 1.5, expectedParticipants: { 2 })
        let p1 = coordinator.registerParticipant()
        _ = coordinator.initialPlan(for: p1, availableEffects: ["matrix", "beams"])

        // P1 finishes at t=1.0, starting dwell until t=2.5
        mockTime = 1.0
        XCTAssertEqual(coordinator.evaluateBoundary(for: p1, cycle: 0, availableEffects: ["matrix", "beams"]), .wait)

        // P2 joins mid-dwell at t=1.5
        mockTime = 1.5
        let p2 = coordinator.registerParticipant()
        let p2Plan = coordinator.initialPlan(for: p2, availableEffects: ["matrix", "beams"])
        XCTAssertEqual(p2Plan.effect, "matrix")

        // At t=2.5, P1's dwell elapses and P1 should proceed to cycle 1 without being blocked by P2
        mockTime = 2.5
        let p1Decision = coordinator.evaluateBoundary(for: p1, cycle: 0, availableEffects: ["matrix", "beams"])
        guard case .proceed(let plan) = p1Decision else { return XCTFail("Expected proceed") }
        XCTAssertEqual(plan.cycle, 1)
        XCTAssertEqual(plan.effect, "beams")
    }

    func testPoolChangeImmediatelyResetsShuffleBag() {
        let coordinator = makeCoordinator(dwellDuration: 0.0, shuffler: { $0 })
        let p1 = coordinator.registerParticipant()

        let first = coordinator.initialPlan(for: p1, availableEffects: ["matrix", "wipe"])
        XCTAssertEqual(first.effect, "matrix")

        // Change pool completely to ["rain", "slide"]
        mockTime = 1.0
        let decision = coordinator.evaluateBoundary(for: p1, cycle: 0, availableEffects: ["rain", "slide"])
        guard case .proceed(let plan) = decision else { return XCTFail("Expected proceed") }
        XCTAssertEqual(plan.effect, "rain", "Changed pool must take effect immediately on next boundary")
    }

    func testDuplicateRegisterParticipantDoesNotResetExistingState() {
        let coordinator = makeCoordinator(dwellDuration: 1.0)
        let p1 = coordinator.registerParticipant()
        _ = coordinator.initialPlan(for: p1, availableEffects: ["matrix"])

        mockTime = 1.0
        _ = coordinator.evaluateBoundary(for: p1, cycle: 0, availableEffects: ["matrix"])
        XCTAssertEqual(coordinator.participants[p1]?.isFinished, true)

        let returnedId = coordinator.registerParticipant(id: p1)
        XCTAssertEqual(returnedId, p1)
        XCTAssertEqual(coordinator.participants[p1]?.isFinished, true)
    }
}
