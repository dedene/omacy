import AppKit
import XCTest
@testable import Omacy

@MainActor
final class OmacyRendererIntegrationTests: XCTestCase {
    private var mockTime: TimeInterval = 0.0

    private func makeCoordinator(
        expectedParticipants: Int = 2,
        seed: UInt64 = 77777,
        dwellDuration: TimeInterval = 1.0,
        maxBarrierWait: TimeInterval = 5.0,
        startBarrierTimeout: TimeInterval = 0.5,
        effects: [String] = ["wipe"]
    ) -> OmacyDisplayCoordinator {
        mockTime = 0.0
        let config = OmacyDisplayCoordinator.Configuration(
            dwellDuration: dwellDuration,
            maxBarrierWait: maxBarrierWait,
            startBarrierTimeout: startBarrierTimeout,
            expectedParticipants: { expectedParticipants },
            clock: { [weak self] in self?.mockTime ?? 0.0 },
            shuffler: { _ in effects },
            seedGenerator: { seed }
        )
        return OmacyDisplayCoordinator(configuration: config)
    }

    private func assertFramesEqual(
        _ first: OmacyStepResult?,
        _ second: OmacyStepResult?,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let first, let second, let firstCells = first.frame.cells, let secondCells = second.frame.cells else {
            return XCTFail("Both renderers must publish cells: \(context)", file: file, line: line)
        }
        XCTAssertEqual(first.steps_taken, second.steps_taken, context, file: file, line: line)
        XCTAssertEqual(first.needs_begin_next, second.needs_begin_next, context, file: file, line: line)
        XCTAssertEqual(first.frame.cols, second.frame.cols, context, file: file, line: line)
        XCTAssertEqual(first.frame.rows, second.frame.rows, context, file: file, line: line)
        guard first.frame.cols == second.frame.cols, first.frame.rows == second.frame.rows else { return }
        XCTAssertEqual(first.frame.clear_r, second.frame.clear_r, context, file: file, line: line)
        XCTAssertEqual(first.frame.clear_g, second.frame.clear_g, context, file: file, line: line)
        XCTAssertEqual(first.frame.clear_b, second.frame.clear_b, context, file: file, line: line)
        XCTAssertEqual(first.frame.clear_a, second.frame.clear_a, context, file: file, line: line)
        let cellCount = Int(first.frame.cols * first.frame.rows)
        for cell in 0..<cellCount {
            XCTAssertEqual(firstCells[cell].glyph, secondCells[cell].glyph, "\(context), cell \(cell)", file: file, line: line)
            XCTAssertEqual(firstCells[cell].fg_r, secondCells[cell].fg_r, "\(context), cell \(cell)", file: file, line: line)
            XCTAssertEqual(firstCells[cell].fg_g, secondCells[cell].fg_g, "\(context), cell \(cell)", file: file, line: line)
            XCTAssertEqual(firstCells[cell].fg_b, secondCells[cell].fg_b, "\(context), cell \(cell)", file: file, line: line)
            XCTAssertEqual(firstCells[cell].fg_a, secondCells[cell].fg_a, "\(context), cell \(cell)", file: file, line: line)
            XCTAssertEqual(firstCells[cell].bg_r, secondCells[cell].bg_r, "\(context), cell \(cell)", file: file, line: line)
            XCTAssertEqual(firstCells[cell].bg_g, secondCells[cell].bg_g, "\(context), cell \(cell)", file: file, line: line)
            XCTAssertEqual(firstCells[cell].bg_b, secondCells[cell].bg_b, "\(context), cell \(cell)", file: file, line: line)
            XCTAssertEqual(firstCells[cell].bg_a, secondCells[cell].bg_a, "\(context), cell \(cell)", file: file, line: line)
            XCTAssertEqual(firstCells[cell].flags, secondCells[cell].flags, "\(context), cell \(cell)", file: file, line: line)
            XCTAssertEqual(firstCells[cell].occupancy, secondCells[cell].occupancy, "\(context), cell \(cell)", file: file, line: line)
        }
    }

    func testTwoRenderersProgressInLockstepWithSharedSeedAndStartBarrier() {
        let coordinator = makeCoordinator(expectedParticipants: 2, seed: 44444)

        let v1 = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let v2 = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        let r1 = OmacyRenderer()
        r1.displayCoordinator = coordinator

        let r2 = OmacyRenderer()
        r2.displayCoordinator = coordinator
        defer { r1.stop(); r2.stop() }

        // Display 1 settles and attaches first at t=0
        mockTime = 0.0
        let mode1 = r1.attach(to: v1, isPreview: false)
        XCTAssertEqual(mode1, .engine, "Renderer 1 must attach in engine mode")
        r1.start()

        // Before Display 2 attaches, start barrier is holding
        XCTAssertNil(coordinator.startEpoch(for: 0), "Start barrier must hold while 1 of 2 displays is registered")

        // Renderer 1 ticks before start epoch -> must not advance simulation
        r1.tick(timestamp: 0.0)
        XCTAssertEqual(r1.lastStepResult?.steps_taken, 0, "Renderer 1 must take 0 steps before start barrier releases")

        // Display 2 settles and attaches at t=0.1s
        mockTime = 0.1
        let mode2 = r2.attach(to: v2, isPreview: false)
        XCTAssertEqual(mode2, .engine, "Renderer 2 must attach in engine mode")
        r2.start()

        // Start barrier is now satisfied at t=0.1s
        XCTAssertEqual(coordinator.startEpoch(for: 0), 0.1)

        // Both renderers share the exact same effect and deterministic seed
        XCTAssertEqual(r1.currentEffect, r2.currentEffect)
        XCTAssertEqual(r1.currentSession?.configuration.seed, 44444)
        XCTAssertEqual(r2.currentSession?.configuration.seed, 44444)
        XCTAssertEqual(r1.currentCycleNumber, 0)
        XCTAssertEqual(r2.currentCycleNumber, 0)

        // Simulate 30 frames of 60Hz display link ticks starting from epoch (t=0.1)
        for frame in 1...30 {
            mockTime = 0.1 + Double(frame) * (1.0 / 60.0)
            r1.tick(timestamp: mockTime)
            r2.tick(timestamp: mockTime)

            assertFramesEqual(r1.lastStepResult, r2.lastStepResult, "Frame \(frame)")
        }
    }

    func testSixtyAndOneHundredTwentyHertzCadencesMatchAtSharedTimestamps() {
        let coordinator = makeCoordinator(expectedParticipants: 2, seed: 55_000, effects: ["beams"])
        let sixtyHertzView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let oneHundredTwentyHertzView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let sixtyHertzRenderer = OmacyRenderer()
        sixtyHertzRenderer.displayCoordinator = coordinator
        let oneHundredTwentyHertzRenderer = OmacyRenderer()
        oneHundredTwentyHertzRenderer.displayCoordinator = coordinator
        defer { sixtyHertzRenderer.stop(); oneHundredTwentyHertzRenderer.stop() }

        _ = sixtyHertzRenderer.attach(to: sixtyHertzView, isPreview: false)
        _ = oneHundredTwentyHertzRenderer.attach(to: oneHundredTwentyHertzView, isPreview: false)
        sixtyHertzRenderer.start()
        oneHundredTwentyHertzRenderer.start()

        for frame in 1...30 {
            let sharedTimestamp = Double(frame) / 60.0
            oneHundredTwentyHertzRenderer.tick(timestamp: sharedTimestamp - (1.0 / 120.0))
            sixtyHertzRenderer.tick(timestamp: sharedTimestamp)
            oneHundredTwentyHertzRenderer.tick(timestamp: sharedTimestamp)
            assertFramesEqual(
                sixtyHertzRenderer.lastStepResult,
                oneHundredTwentyHertzRenderer.lastStepResult,
                "Shared timestamp frame \(frame)"
            )
        }

        // A display link may pause long enough to owe more steps than the engine
        // accepts in one call. Repeated ticks at the same timestamp must drain
        // that backlog instead of silently discarding it.
        let catchUpTimestamp = 40.0 / 60.0
        for frame in 31...40 {
            sixtyHertzRenderer.tick(timestamp: Double(frame) / 60.0)
        }
        for _ in 1...3 {
            oneHundredTwentyHertzRenderer.tick(timestamp: catchUpTimestamp)
        }
        sixtyHertzRenderer.tick(timestamp: catchUpTimestamp)
        oneHundredTwentyHertzRenderer.tick(timestamp: catchUpTimestamp)
        assertFramesEqual(
            sixtyHertzRenderer.lastStepResult,
            oneHundredTwentyHertzRenderer.lastStepResult,
            "After draining a ten-step display-link gap"
        )
    }

    func testTwoRenderersSynchronizeAtEffectBoundaryWithTransactionalAdvancement() {
        let coordinator = makeCoordinator(expectedParticipants: 2, seed: 12345, dwellDuration: 1.0, effects: ["wipe", "beams"])

        let v1 = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let v2 = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        let r1 = OmacyRenderer()
        r1.displayCoordinator = coordinator

        let r2 = OmacyRenderer()
        r2.displayCoordinator = coordinator
        defer { r1.stop(); r2.stop() }

        mockTime = 0.0
        _ = r1.attach(to: v1, isPreview: false)
        _ = r2.attach(to: v2, isPreview: false)
        r1.start()
        r2.start()

        XCTAssertEqual(coordinator.startEpoch(for: 0), 0.0)

        // Run until effect needs transition (or max 3000 steps)
        var reachedBoundary = false
        var step = 0
        while step < 3000 && !reachedBoundary {
            step += 1
            mockTime += 1.0 / 60.0
            r1.tick(timestamp: mockTime)
            r2.tick(timestamp: mockTime)

            if let needs1 = r1.lastStepResult?.needs_begin_next, needs1 != 0 {
                reachedBoundary = true
                XCTAssertEqual(r2.lastStepResult?.needs_begin_next, 1, "Renderer 2 must reach boundary at the exact same step as Renderer 1")
            }
        }

        XCTAssertTrue(reachedBoundary, "Both renderers should complete their effect within 3000 frames")

        // Mid-dwell check: dwell duration is 1.0s. At 0.5s after barrier, both must still be on cycle 0
        mockTime += 0.5
        r1.tick(timestamp: mockTime)
        r2.tick(timestamp: mockTime)
        XCTAssertEqual(r1.currentCycleNumber, 0)
        XCTAssertEqual(r2.currentCycleNumber, 0)
        XCTAssertEqual(coordinator.currentCycle, 0)

        // Advance mock time past dwell duration (dwell completed)
        mockTime += 0.6
        // Tick Renderer 1: receives proposal and commits cycle 1
        r1.tick(timestamp: mockTime)
        XCTAssertEqual(r1.currentCycleNumber, 1, "Renderer 1 must advance to cycle 1")
        // Transactional: coordinator global cycle must not advance until ALL participants commit
        XCTAssertEqual(coordinator.currentCycle, 0, "Coordinator currentCycle must remain 0 while Renderer 2 has not committed")

        // Tick Renderer 2: receives proposal and commits cycle 1
        r2.tick(timestamp: mockTime)
        XCTAssertEqual(r2.currentCycleNumber, 1, "Renderer 2 must advance to cycle 1")
        XCTAssertEqual(coordinator.currentCycle, 1, "Coordinator currentCycle must advance to 1 once both have committed")

        // Both renderers must share the new effect and seed in cycle 1
        XCTAssertEqual(r1.currentEffect, r2.currentEffect)
        XCTAssertEqual(r1.currentSession?.configuration.seed, r2.currentSession?.configuration.seed)

    }

    func testBoundaryCommitSkewUsesSharedStartEpoch() {
        let coordinator = makeCoordinator(
            expectedParticipants: 2,
            seed: 18_000,
            dwellDuration: 0.0,
            effects: ["wipe"]
        )
        let firstView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let secondView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let firstRenderer = OmacyRenderer()
        firstRenderer.displayCoordinator = coordinator
        let secondRenderer = OmacyRenderer()
        secondRenderer.displayCoordinator = coordinator
        defer { firstRenderer.stop(); secondRenderer.stop() }

        _ = firstRenderer.attach(to: firstView, isPreview: false)
        _ = secondRenderer.attach(to: secondView, isPreview: false)
        firstRenderer.start()
        secondRenderer.start()

        var frame = 0
        while frame < 3_000 && firstRenderer.currentCycleNumber == 0 && secondRenderer.currentCycleNumber == 0 {
            frame += 1
            mockTime += 1.0 / 60.0
            firstRenderer.tick(timestamp: mockTime)
            secondRenderer.tick(timestamp: mockTime)
        }
        XCTAssertEqual(secondRenderer.currentCycleNumber, 1)
        XCTAssertEqual(firstRenderer.currentCycleNumber, 0)
        XCTAssertNil(coordinator.startEpoch(for: 1), "The next cycle must not start before every engine commits")

        mockTime += 0.010
        firstRenderer.tick(timestamp: mockTime)
        XCTAssertEqual(coordinator.currentCycle, 1)
        let sharedEpoch = mockTime
        XCTAssertEqual(coordinator.startEpoch(for: 1), sharedEpoch)

        mockTime = sharedEpoch + 0.050
        firstRenderer.tick(timestamp: mockTime)
        secondRenderer.tick(timestamp: mockTime)

        assertFramesEqual(
            firstRenderer.lastStepResult,
            secondRenderer.lastStepResult,
            "First frame after a skewed boundary commit"
        )
    }

    func testRejectedCoordinatedTransitionFallsBackOnlyFailedRenderer() {
        let coordinator = makeCoordinator(
            expectedParticipants: 2,
            seed: 22_000,
            dwellDuration: 0.0,
            effects: ["wipe", "beams"]
        )
        var rejectingAPI = OmacyEngineSession.API.live
        rejectingAPI.beginNext = { _, _, _, _ in OMACY_ERR_INVALID_ARG }
        rejectingAPI.errorMessage = { _ in "forced coordinated rejection" }

        let healthyView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let failedView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let healthyRenderer = OmacyRenderer()
        healthyRenderer.displayCoordinator = coordinator
        let failedRenderer = OmacyRenderer(engineAPI: rejectingAPI)
        failedRenderer.displayCoordinator = coordinator
        defer { healthyRenderer.stop(); failedRenderer.stop() }
        var failedRendererFellBack = false
        failedRenderer.onEngineUnavailable = { failedRendererFellBack = true }

        _ = healthyRenderer.attach(to: healthyView, isPreview: false)
        _ = failedRenderer.attach(to: failedView, isPreview: false)
        healthyRenderer.start()
        failedRenderer.start()

        var frame = 0
        while frame < 3_000 && (!failedRendererFellBack || coordinator.currentCycle == 0) {
            frame += 1
            mockTime += 1.0 / 60.0
            healthyRenderer.tick(timestamp: mockTime)
            failedRenderer.tick(timestamp: mockTime)
        }

        XCTAssertTrue(failedRendererFellBack)
        XCTAssertEqual(coordinator.activeParticipantCount, 1)
        XCTAssertEqual(coordinator.currentCycle, 1)
        XCTAssertEqual(healthyRenderer.currentCycleNumber, 1)
        XCTAssertTrue(healthyRenderer.usesEngine)
        XCTAssertFalse(failedRenderer.usesEngine)
    }

    func testRejectedCoordinatedSessionReplacementFallsBackOnlyFailedRenderer() {
        let coordinator = makeCoordinator(expectedParticipants: 2, seed: 23_000, dwellDuration: 0.0)
        var settings = OmacySettings(effects: ["wipe"])
        var snapshot = OmacyConfigSnapshot(settings: settings, art: "OMACY", diagnostic: nil)
        let configurationLoader = { snapshot }
        var createCount = 0
        var rejectingAPI = OmacyEngineSession.API.live
        let liveCreate = rejectingAPI.create
        rejectingAPI.create = { configuration, cols, rows in
            createCount += 1
            return createCount == 1
                ? liveCreate(configuration, cols, rows)
                : (OMACY_ERR_INVALID_ARG, nil)
        }
        rejectingAPI.errorMessage = { _ in "forced replacement rejection" }

        let healthyView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let failedView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let healthyRenderer = OmacyRenderer(configurationLoader: configurationLoader)
        healthyRenderer.displayCoordinator = coordinator
        let failedRenderer = OmacyRenderer(
            engineAPI: rejectingAPI,
            configurationLoader: configurationLoader
        )
        failedRenderer.displayCoordinator = coordinator
        defer { healthyRenderer.stop(); failedRenderer.stop() }
        var failedRendererFellBack = false
        failedRenderer.onEngineUnavailable = { failedRendererFellBack = true }

        _ = healthyRenderer.attach(to: healthyView, isPreview: false)
        _ = failedRenderer.attach(to: failedView, isPreview: false)
        healthyRenderer.start()
        failedRenderer.start()
        settings.background = "#010203"
        snapshot = OmacyConfigSnapshot(settings: settings, art: "OMACY", diagnostic: nil)

        var frame = 0
        while frame < 3_000 && (!failedRendererFellBack || coordinator.currentCycle == 0) {
            frame += 1
            mockTime += 1.0 / 60.0
            healthyRenderer.tick(timestamp: mockTime)
            failedRenderer.tick(timestamp: mockTime)
        }

        XCTAssertTrue(failedRendererFellBack)
        XCTAssertFalse(failedRenderer.usesEngine)
        XCTAssertTrue(healthyRenderer.usesEngine)
        XCTAssertEqual(coordinator.activeParticipantCount, 1)
        XCTAssertEqual(coordinator.currentCycle, 1)
        XCTAssertEqual(healthyRenderer.currentSession?.configuration.background.0, 1)
        XCTAssertEqual(healthyRenderer.currentSession?.configuration.background.1, 2)
        XCTAssertEqual(healthyRenderer.currentSession?.configuration.background.2, 3)
    }

    func testReplacementRendererResynchronizesAtNextBoundary() {
        let coordinator = makeCoordinator(
            expectedParticipants: 2,
            seed: 33_000,
            dwellDuration: 0.0,
            effects: ["beams"]
        )
        let continuingView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let departingView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let replacementView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let continuingRenderer = OmacyRenderer()
        continuingRenderer.displayCoordinator = coordinator
        let departingRenderer = OmacyRenderer()
        departingRenderer.displayCoordinator = coordinator
        defer { continuingRenderer.stop(); departingRenderer.stop() }

        _ = continuingRenderer.attach(to: continuingView, isPreview: false)
        _ = departingRenderer.attach(to: departingView, isPreview: false)
        continuingRenderer.start()
        departingRenderer.start()

        var frame = 0
        while frame < 3_000 && coordinator.currentCycle == 0 {
            frame += 1
            mockTime += 1.0 / 60.0
            continuingRenderer.tick(timestamp: mockTime)
            departingRenderer.tick(timestamp: mockTime)
        }
        XCTAssertEqual(coordinator.currentCycle, 1)

        departingRenderer.stop()
        let replacementRenderer = OmacyRenderer()
        replacementRenderer.displayCoordinator = coordinator
        defer { replacementRenderer.stop() }
        _ = replacementRenderer.attach(to: replacementView, isPreview: false)
        replacementRenderer.start()

        XCTAssertEqual(continuingRenderer.currentSession?.configuration.seed, 33_001)
        XCTAssertEqual(replacementRenderer.currentSession?.configuration.seed, 33_001)

        frame = 0
        while frame < 3_000 && coordinator.currentCycle == 1 {
            frame += 1
            mockTime += 1.0 / 60.0
            continuingRenderer.tick(timestamp: mockTime)
            replacementRenderer.tick(timestamp: mockTime)
        }
        XCTAssertEqual(coordinator.currentCycle, 2)
        XCTAssertEqual(continuingRenderer.currentCycleNumber, 2)
        XCTAssertEqual(replacementRenderer.currentCycleNumber, 2)

        for sample in 1...30 {
            mockTime += 1.0 / 60.0
            continuingRenderer.tick(timestamp: mockTime)
            replacementRenderer.tick(timestamp: mockTime)

            assertFramesEqual(
                continuingRenderer.lastStepResult,
                replacementRenderer.lastStepResult,
                "Resynchronized sample \(sample)"
            )
        }
    }

    func testTimedOutRendererCatchesUpAfterMissingMultipleCycles() {
        let coordinator = makeCoordinator(
            expectedParticipants: 2,
            seed: 35_000,
            dwellDuration: 0.0,
            maxBarrierWait: 0.05,
            effects: ["beams"]
        )
        var createdSeeds: [UInt64?] = []
        var recordingAPI = OmacyEngineSession.API.live
        let liveCreate = recordingAPI.create
        recordingAPI.create = { configuration, cols, rows in
            createdSeeds.append(configuration.seed)
            return liveCreate(configuration, cols, rows)
        }

        let continuingRenderer = OmacyRenderer()
        continuingRenderer.displayCoordinator = coordinator
        let staleRenderer = OmacyRenderer(engineAPI: recordingAPI)
        staleRenderer.displayCoordinator = coordinator
        let continuingView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let staleView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        defer { continuingRenderer.stop(); staleRenderer.stop() }

        _ = continuingRenderer.attach(to: continuingView, isPreview: false)
        _ = staleRenderer.attach(to: staleView, isPreview: false)
        continuingRenderer.start()
        staleRenderer.start()

        var frame = 0
        while frame < 6_000 && coordinator.currentCycle < 2 {
            frame += 1
            mockTime += 1.0 / 60.0
            continuingRenderer.tick(timestamp: mockTime)
        }
        XCTAssertEqual(coordinator.currentCycle, 2)
        XCTAssertEqual(coordinator.activeParticipantCount, 1)

        staleRenderer.tick(timestamp: mockTime)

        XCTAssertEqual(staleRenderer.currentCycleNumber, 2)
        XCTAssertEqual(staleRenderer.currentSession?.configuration.seed, 35_002)
        XCTAssertEqual(createdSeeds, [35_000, 35_002])
        XCTAssertEqual(coordinator.activeParticipantCount, 2)
    }

    func testChangingSynchronizationModeRecreatesSessionsWithCorrectSeedPolicy() {
        let coordinator = makeCoordinator(
            expectedParticipants: 2,
            seed: 44_000,
            dwellDuration: 0.0,
            effects: ["beams"]
        )
        var settings = OmacySettings(effects: ["beams"])
        settings.syncDisplays = false
        var snapshot = OmacyConfigSnapshot(settings: settings, art: "OMACY", diagnostic: nil)
        let configurationLoader = { snapshot }
        var createdSeeds: [UInt64?] = []
        var recordingAPI = OmacyEngineSession.API.live
        let liveCreate = recordingAPI.create
        recordingAPI.create = { configuration, cols, rows in
            createdSeeds.append(configuration.seed)
            return liveCreate(configuration, cols, rows)
        }
        let firstView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let secondView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let firstRenderer = OmacyRenderer(engineAPI: recordingAPI, configurationLoader: configurationLoader)
        firstRenderer.displayCoordinator = coordinator
        let secondRenderer = OmacyRenderer(engineAPI: recordingAPI, configurationLoader: configurationLoader)
        secondRenderer.displayCoordinator = coordinator
        defer {
            firstRenderer.stop()
            secondRenderer.stop()
        }

        _ = firstRenderer.attach(to: firstView, isPreview: false)
        _ = secondRenderer.attach(to: secondView, isPreview: false)
        firstRenderer.start()
        secondRenderer.start()
        XCTAssertEqual(coordinator.activeParticipantCount, 0)
        XCTAssertNil(firstRenderer.currentSession?.configuration.seed)
        XCTAssertNil(secondRenderer.currentSession?.configuration.seed)

        settings.syncDisplays = true
        snapshot = OmacyConfigSnapshot(settings: settings, art: "OMACY", diagnostic: nil)
        var frame = 0
        while frame < 6_000 {
            let firstSeed = firstRenderer.currentSession?.configuration.seed
            let secondSeed = secondRenderer.currentSession?.configuration.seed
            if coordinator.activeParticipantCount == 2,
               firstRenderer.currentCycleNumber == coordinator.currentCycle,
               secondRenderer.currentCycleNumber == coordinator.currentCycle,
               firstSeed != nil, firstSeed == secondSeed {
                break
            }
            frame += 1
            mockTime += 1.0 / 60.0
            firstRenderer.tick(timestamp: mockTime)
            secondRenderer.tick(timestamp: mockTime)
        }
        XCTAssertEqual(coordinator.activeParticipantCount, 2)
        XCTAssertEqual(firstRenderer.currentCycleNumber, coordinator.currentCycle)
        XCTAssertEqual(secondRenderer.currentCycleNumber, coordinator.currentCycle)
        XCTAssertEqual(firstRenderer.currentSession?.configuration.seed, coordinator.seed(for: coordinator.currentCycle))
        XCTAssertEqual(secondRenderer.currentSession?.configuration.seed, coordinator.seed(for: coordinator.currentCycle))

        settings.syncDisplays = false
        snapshot = OmacyConfigSnapshot(settings: settings, art: "OMACY", diagnostic: nil)
        frame = 0
        while frame < 6_000 {
            if coordinator.activeParticipantCount == 0,
               firstRenderer.currentSession?.configuration.seed == nil,
               secondRenderer.currentSession?.configuration.seed == nil {
                break
            }
            frame += 1
            mockTime += 1.0 / 60.0
            firstRenderer.tick(timestamp: mockTime)
            secondRenderer.tick(timestamp: mockTime)
        }
        XCTAssertEqual(coordinator.activeParticipantCount, 0)
        XCTAssertNil(firstRenderer.currentSession?.configuration.seed)
        XCTAssertNil(secondRenderer.currentSession?.configuration.seed)
        guard createdSeeds.count >= 6 else {
            return XCTFail("Expected initial, enabling, and disabling session creation for both renderers")
        }
        XCTAssertNil(createdSeeds[createdSeeds.count - 2])
        XCTAssertNil(createdSeeds[createdSeeds.count - 1])
    }
}
