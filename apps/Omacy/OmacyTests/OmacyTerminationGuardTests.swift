import AppKit
import XCTest
@testable import Omacy

@MainActor
final class OmacyTerminationGuardTests: XCTestCase {
    private final class Owner {}

    /// Lets a test hold a save open and release it on demand.
    private final class SaveGate {
        private var continuation: CheckedContinuation<Bool, Never>?
        private(set) var started = false

        func wait() async -> Bool {
            started = true
            return await withCheckedContinuation { continuation = $0 }
        }

        func finish(_ saved: Bool) {
            let pending = continuation
            continuation = nil
            pending?.resume(returning: saved)
        }
    }

    // MARK: - Decisions

    func testCleanDraftTerminatesWithoutPrompting() {
        var prompts = 0
        let sut = makeGuard(choice: .cancel, onPrompt: { prompts += 1 })
        let owner = Owner()
        register(sut, owner: owner, isDirty: { false })

        XCTAssertEqual(sut.requestTermination { _ in }, .terminateNow)
        XCTAssertEqual(prompts, 0)
    }

    func testUnregisteredGuardTerminatesImmediately() {
        var prompts = 0
        let sut = makeGuard(choice: .cancel, onPrompt: { prompts += 1 })
        let owner = Owner()
        register(sut, owner: owner, isDirty: { true })
        sut.unregister(owner: owner)

        XCTAssertEqual(sut.requestTermination { _ in }, .terminateNow)
        XCTAssertEqual(prompts, 0)
    }

    func testDeallocatedOwnerIsTreatedAsUnregistered() {
        var prompts = 0
        let sut = makeGuard(choice: .cancel, onPrompt: { prompts += 1 })
        do {
            let owner = Owner()
            register(sut, owner: owner, isDirty: { true })
            XCTAssertEqual(sut.requestTermination { _ in }, .cancel)
        }

        XCTAssertEqual(sut.requestTermination { _ in }, .terminateNow)
        XCTAssertEqual(prompts, 1)
    }

    func testUnregisteringFromAnotherOwnerKeepsRegistration() {
        let sut = makeGuard(choice: .cancel)
        let owner = Owner()
        register(sut, owner: owner, isDirty: { true })
        sut.unregister(owner: Owner())

        XCTAssertEqual(sut.requestTermination { _ in }, .cancel)
    }

    func testCancelStopsTermination() {
        var saves = 0
        var discards = 0
        let sut = makeGuard(choice: .cancel)
        let owner = Owner()
        register(
            sut, owner: owner, isDirty: { true },
            save: { saves += 1; return true }, discard: { discards += 1 }
        )

        XCTAssertEqual(sut.requestTermination { _ in }, .cancel)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(discards, 0)
    }

    func testDiscardDropsChangesAndTerminates() {
        var discards = 0
        let sut = makeGuard(choice: .discard)
        let owner = Owner()
        register(sut, owner: owner, isDirty: { true }, discard: { discards += 1 })

        XCTAssertEqual(sut.requestTermination { _ in }, .terminateNow)
        XCTAssertEqual(discards, 1)
    }

    // MARK: - Deferred save

    func testSaveDefersReplyUntilTheSaveActuallyFinishes() async {
        let sut = makeGuard(choice: .save)
        let owner = Owner()
        let gate = SaveGate()
        register(sut, owner: owner, isDirty: { true }, save: { await gate.wait() })

        var reply: Bool?
        XCTAssertEqual(sut.requestTermination { reply = $0 }, .terminateLater)
        XCTAssertNil(reply)
        await yieldUntil { gate.started }
        XCTAssertTrue(gate.started)
        XCTAssertNil(reply)

        gate.finish(true)
        await yieldUntil { reply != nil }
        XCTAssertEqual(reply, true)
    }

    func testFailedSaveWarnsAndCancelsTermination() async {
        var warnings = 0
        let sut = makeGuard(choice: .save, onSaveFailure: { warnings += 1 })
        let owner = Owner()
        register(sut, owner: owner, isDirty: { true }, save: { false })

        let replied = expectation(description: "reply")
        var reply: Bool?
        XCTAssertEqual(sut.requestTermination { reply = $0; replied.fulfill() }, .terminateLater)
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(reply, false)
        XCTAssertEqual(warnings, 1)
    }

    func testSuccessfulSaveDoesNotWarn() async {
        var warnings = 0
        let sut = makeGuard(choice: .save, onSaveFailure: { warnings += 1 })
        let owner = Owner()
        register(sut, owner: owner, isDirty: { true }, save: { true })

        let replied = expectation(description: "reply")
        var reply: Bool?
        XCTAssertEqual(sut.requestTermination { reply = $0; replied.fulfill() }, .terminateLater)
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(reply, true)
        XCTAssertEqual(warnings, 0)
    }

    // MARK: - Re-entrancy

    func testRequestDuringOpenAlertIsRefusedWithoutStackingAnotherAlert() {
        var prompts = 0
        var nested: OmacyTerminationGuard.Outcome?
        let sut = OmacyTerminationGuard()
        let owner = Owner()
        sut.presentAlert = { [weak sut] in
            prompts += 1
            if prompts == 1 { nested = sut?.requestTermination { _ in } }
            return .discard
        }
        var discards = 0
        register(sut, owner: owner, isDirty: { true }, discard: { discards += 1 })

        XCTAssertEqual(sut.requestTermination { _ in }, .terminateNow)
        XCTAssertEqual(nested, .cancel)
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(discards, 1)
    }

    func testRequestDuringInFlightSaveDefersToTheRunningSave() async {
        var prompts = 0
        let sut = makeGuard(choice: .save, onPrompt: { prompts += 1 })
        let owner = Owner()
        let gate = SaveGate()
        register(sut, owner: owner, isDirty: { true }, save: { await gate.wait() })

        var replies: [Bool] = []
        XCTAssertEqual(sut.requestTermination { replies.append($0) }, .terminateLater)
        await yieldUntil { gate.started }
        XCTAssertEqual(sut.requestTermination { replies.append($0) }, .terminateLater)
        XCTAssertEqual(prompts, 1)

        gate.finish(true)
        await yieldUntil { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
    }

    // MARK: - Coordinator wiring

    func testCoordinatorRegistersItselfWithTheInjectedGuard() {
        let sut = makeGuard(choice: .cancel)
        let coordinator = OmacyWindowCloseGuard.Coordinator(terminationGuard: sut)
        coordinator.isDirty = true

        XCTAssertEqual(sut.requestTermination { _ in }, .cancel)
    }

    func testCoordinatorUninstallKeepsTerminationRegistration() {
        let sut = makeGuard(choice: .cancel)
        let coordinator = OmacyWindowCloseGuard.Coordinator(terminationGuard: sut)
        coordinator.isDirty = true
        coordinator.uninstall()

        XCTAssertEqual(sut.requestTermination { _ in }, .cancel)
    }

    func testDismantlingTheViewUnregistersTheCoordinator() {
        let sut = makeGuard(choice: .cancel)
        let coordinator = OmacyWindowCloseGuard.Coordinator(terminationGuard: sut)
        coordinator.isDirty = true
        OmacyWindowCloseGuard.dismantleNSView(WindowObserverView(frame: .zero), coordinator: coordinator)

        XCTAssertEqual(sut.requestTermination { _ in }, .terminateNow)
    }

    func testWindowShouldCloseAsksOnlyWhileDirty() {
        var prompts = 0
        let coordinator = OmacyWindowCloseGuard.Coordinator(terminationGuard: OmacyTerminationGuard())
        coordinator.presentAlert = { prompts += 1; return .cancel }
        let window = NSWindow()

        coordinator.isDirty = true
        XCTAssertFalse(coordinator.windowShouldClose(window))
        XCTAssertEqual(prompts, 1)

        coordinator.isDirty = false
        XCTAssertTrue(coordinator.windowShouldClose(window))
        XCTAssertEqual(prompts, 1)
    }

    // MARK: - Helpers

    private func yieldUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
    }

    private func makeGuard(
        choice: OmacyUnsavedChangesChoice,
        onPrompt: @escaping @MainActor () -> Void = {},
        onSaveFailure: @escaping @MainActor () -> Void = {}
    ) -> OmacyTerminationGuard {
        let sut = OmacyTerminationGuard()
        sut.presentAlert = { onPrompt(); return choice }
        sut.presentSaveFailureAlert = onSaveFailure
        return sut
    }

    private func register(
        _ sut: OmacyTerminationGuard,
        owner: AnyObject,
        isDirty: @escaping @MainActor () -> Bool,
        save: @escaping @MainActor () async -> Bool = { true },
        discard: @escaping @MainActor () -> Void = {}
    ) {
        sut.register(owner: owner, isDirty: isDirty, save: save, discard: discard)
    }
}
