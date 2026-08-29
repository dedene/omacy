import XCTest
@testable import Omacy

final class OmacyPinnedPreviewStateTests: XCTestCase {
    private let first = OmacyPinnedContent(art: "first", effect: "matrix", background: "#000000", fontSize: 20)
    private let second = OmacyPinnedContent(art: "second", effect: "rain", background: "#111111", fontSize: 18)

    func testPinnedThenUnpinnedPublicCommitClearsCommittedState() {
        var state = OmacyPinnedPreviewState(desired: first)
        state.commitPinned(first)
        state.desired = nil
        XCTAssertNotNil(state.committed, "old mirrors remain paired until public content commits")
        XCTAssertTrue(state.usesPinnedLayout, "transactional unpin keeps active pinned sizing")
        XCTAssertFalse(
            state.candidateUsesPinnedLayout(isPreview: false),
            "off-side public content must prepare public geometry before the atomic commit"
        )
        state.commitPublic()
        XCTAssertNil(state.committed)
        XCTAssertFalse(state.usesPinnedLayout, "public sizing starts only after public commit")
    }

    func testRejectedIdentityDoesNotRetryUntilDesiredContentChanges() {
        var state = OmacyPinnedPreviewState(desired: first)
        XCTAssertFalse(state.shouldRetry(content: first, rejectedIdentityMatches: true, canRun: true))
        state.desired = second
        XCTAssertTrue(state.shouldRetry(content: second, rejectedIdentityMatches: false, canRun: true))
    }

    func testRecoverableFailureRetriesDesiredUncommittedContent() {
        var state = OmacyPinnedPreviewState(desired: first)
        state.commitPinned(first)
        state.desired = second
        XCTAssertTrue(state.shouldRetry(content: second, rejectedIdentityMatches: false, canRun: true))
        XCTAssertEqual(state.committed, first, "failed replacement must keep the active mirrors")
    }

    func testCommittedDesiredContentIsEqualitySuppressed() {
        var state = OmacyPinnedPreviewState(desired: first)
        XCTAssertFalse(state.suppressesRequest(first))
        state.commitPinned(first)
        XCTAssertTrue(state.suppressesRequest(first))
    }

    func testRejectedGeometryTupleIsAttemptedOnceAndChangedDimensionsRetry() {
        var latch = OmacyReplacementRejectionLatch()
        let original = OmacyReplacementRejectionLatch.identity(
            semanticConfiguration: "active-config",
            cols: 80,
            rows: 24
        )
        let resized = OmacyReplacementRejectionLatch.identity(
            semanticConfiguration: "active-config",
            cols: 100,
            rows: 30
        )
        var attempts = 0
        var reports = 0

        if latch.shouldAttempt(original) {
            attempts += 1
            reports += 1
            latch.reject(original)
        }
        if latch.shouldAttempt(original) {
            attempts += 1
            reports += 1
        }

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(reports, 1)
        XCTAssertTrue(latch.shouldAttempt(resized), "changed dimensions form a new replacement identity")
    }

    func testBoundaryLoadsExactExternalArtPoolAndGeometryIdentityWithoutPrematurePinnedPromotion() {
        let coordinator = OmacyTransitionCoordinator()
        let active = OmacyConfigSnapshot(
            settings: OmacySettings(effects: ["wipe"]), art: "OLD ART", diagnostic: nil
        )
        let external = OmacyConfigSnapshot(
            settings: OmacySettings(effects: ["beams", "matrix"]), art: "NEW AGENT ART", diagnostic: nil
        )
        let candidate = coordinator.boundaryConfiguration(current: active) { external }
        let identity = coordinator.replacementIdentity(
            settings: candidate.settings, art: candidate.art, cols: 100, rows: 30
        )

        XCTAssertEqual(candidate.art, "NEW AGENT ART")
        XCTAssertEqual(coordinator.engineConfiguration(settings: candidate.settings, art: candidate.art).effects, ["beams", "matrix"])
        XCTAssertTrue(identity.hasSuffix(":100x30"))
        XCTAssertFalse(coordinator.usesPinnedLayout, "candidate resolution must not promote active mirrors")
    }

    func testResizeReturningToCommittedGeometryClearsStalePendingIntent() {
        XCTAssertEqual(
            OmacyGeometryIntent.resolve(
                committedCols: 80, committedRows: 24,
                candidateCols: 100, candidateRows: 30, changesFont: false
            ),
            .stage
        )
        XCTAssertEqual(
            OmacyGeometryIntent.resolve(
                committedCols: 80, committedRows: 24,
                candidateCols: 80, candidateRows: 24, changesFont: false
            ),
            .clear,
            "the authoritative A callback cancels a previously staged A→B resize"
        )
    }

    func testBoundaryOperationSendsExactCandidateAndCommitsMirrorsOnlyOnSuccess() {
        let coordinator = OmacyTransitionCoordinator()
        let settings = OmacySettings(effects: ["beams", "matrix"])
        let plan = coordinator.boundaryPlan(settings: settings, art: "NEW ART", cols: 100, rows: 30)
        var activeArt = "OLD ART"
        var received: OmacyBoundaryPlan?

        XCTAssertFalse(coordinator.performBoundary(
            plan,
            transition: { candidate in received = candidate; return false },
            commit: { accepted in activeArt = accepted.art }
        ))
        XCTAssertEqual(received?.art, "NEW ART")
        XCTAssertEqual(received?.configuration.effects, ["beams", "matrix"])
        XCTAssertEqual(received?.cols, 100)
        XCTAssertEqual(received?.rows, 30)
        XCTAssertEqual(activeArt, "OLD ART", "failed engine transition must preserve active mirrors")

        XCTAssertTrue(coordinator.performBoundary(
            plan,
            transition: { candidate in received = candidate; return true },
            commit: { accepted in activeArt = accepted.art }
        ))
        XCTAssertEqual(activeArt, "NEW ART", "success promotes content and geometry from one accepted plan")
    }
}
