import XCTest
@testable import Omacy

final class OmacyEditorStateTests: XCTestCase {
    private let initial = OmacyConfigSnapshot(
        settings: OmacySettings(effects: ["beams"]), art: "INITIAL", diagnostic: nil
    )

    func testInitialSnapshotPopulatesCleanBaselineAndDraft() {
        let state = OmacyEditorState(snapshot: initial)

        XCTAssertEqual(state.baseline, initial)
        XCTAssertEqual(state.draftSettings, initial.settings)
        XCTAssertEqual(state.draftArt, initial.art)
        XCTAssertFalse(state.isDirty)
        XCTAssertNil(state.pendingExternal)
        XCTAssertNil(state.diagnostic)
    }

    func testDraftEqualityDeterminesDirtyState() {
        var state = OmacyEditorState(snapshot: initial)

        state.draftArt = "EDITED"
        XCTAssertTrue(state.isDirty)
        state.draftArt = initial.art
        XCTAssertFalse(state.isDirty)

        state.draftSettings = OmacySettings(effects: ["matrix"])
        XCTAssertTrue(state.isDirty)
        state.draftSettings = initial.settings
        XCTAssertFalse(state.isDirty)
    }

    func testValidExternalSnapshotIsAdoptedWhenClean() {
        var state = OmacyEditorState(snapshot: initial)
        let external = snapshot(art: "EXTERNAL")

        state.observeExternal(external)

        XCTAssertEqual(state.baseline, external)
        XCTAssertEqual(state.draftArt, "EXTERNAL")
        XCTAssertFalse(state.isDirty)
        XCTAssertNil(state.pendingExternal)
    }

    func testValidExternalSnapshotStagesConflictWhenDirty() {
        var state = OmacyEditorState(snapshot: initial)
        state.draftArt = "MY DRAFT"
        let external = snapshot(art: "EXTERNAL")

        state.observeExternal(external)

        XCTAssertEqual(state.baseline, initial)
        XCTAssertEqual(state.draftArt, "MY DRAFT")
        XCTAssertEqual(state.pendingExternal, external)
        XCTAssertNil(state.diagnostic)
    }

    func testDirtyDraftDoesNotConflictWhenExternalSnapshotStillMatchesBaseline() {
        var state = OmacyEditorState(snapshot: initial)
        state.draftArt = "MY DRAFT"

        state.observeExternal(initial)

        XCTAssertEqual(state.baseline, initial)
        XCTAssertEqual(state.draftArt, "MY DRAFT")
        XCTAssertNil(state.pendingExternal)
        XCTAssertNil(state.diagnostic)
    }

    func testEditedBootstrapDraftDoesNotConflictWithUnchangedBootstrapSnapshot() {
        let bootstrap = OmacyConfigSnapshot(
            settings: OmacySettings(),
            art: "BUNDLED",
            diagnostic: nil,
            origin: .bootstrapDefaults
        )
        var state = OmacyEditorState(snapshot: bootstrap)
        state.draftArt = "MY DRAFT"

        state.observeExternal(bootstrap)

        XCTAssertEqual(state.baseline, bootstrap)
        XCTAssertEqual(state.draftArt, "MY DRAFT")
        XCTAssertNil(state.pendingExternal)
    }

    func testInitialDiagnosticIsTransientAndDoesNotChangeConfigurationIdentity() {
        let invalidInitial = OmacyConfigSnapshot(
            settings: initial.settings, art: initial.art, diagnostic: "settings.json is invalid"
        )
        var state = OmacyEditorState(snapshot: invalidInitial)
        state.draftArt = "MY DRAFT"

        state.observeExternal(initial)

        XCTAssertEqual(state.baseline, initial)
        XCTAssertEqual(state.draftArt, "MY DRAFT")
        XCTAssertNil(state.pendingExternal)
        XCTAssertNil(state.diagnostic)
    }

    func testInvalidExternalSnapshotPreservesCleanEditingStateAndExposesDiagnostic() {
        var state = OmacyEditorState(snapshot: initial)

        state.observeExternal(snapshot(art: "FALLBACK", diagnostic: "settings.json is invalid"))

        XCTAssertEqual(state.baseline, initial)
        XCTAssertEqual(state.draftSettings, initial.settings)
        XCTAssertEqual(state.draftArt, initial.art)
        XCTAssertFalse(state.isDirty)
        XCTAssertNil(state.pendingExternal)
        XCTAssertEqual(state.diagnostic, "settings.json is invalid")
    }

    func testInvalidExternalSnapshotPreservesEditingAndPendingConflict() {
        var state = OmacyEditorState(snapshot: initial)
        state.draftArt = "MY DRAFT"
        let pending = snapshot(art: "EXTERNAL")
        state.observeExternal(pending)

        state.observeExternal(snapshot(art: "FALLBACK", diagnostic: "settings.json is invalid"))

        XCTAssertEqual(state.baseline, initial)
        XCTAssertEqual(state.draftArt, "MY DRAFT")
        XCTAssertEqual(state.pendingExternal, pending)
        XCTAssertEqual(state.diagnostic, "settings.json is invalid")
    }

    func testExplicitValidReloadAdoptsSnapshotAndClearsConflictAndDiagnostic() {
        var state = OmacyEditorState(snapshot: initial)
        state.draftArt = "MY DRAFT"
        state.observeExternal(snapshot(art: "PENDING"))
        state.observeExternal(snapshot(art: "FALLBACK", diagnostic: "invalid"))
        let reloaded = snapshot(art: "RELOADED")

        state.reload(reloaded)

        XCTAssertEqual(state.baseline, reloaded)
        XCTAssertEqual(state.draftArt, "RELOADED")
        XCTAssertFalse(state.isDirty)
        XCTAssertNil(state.pendingExternal)
        XCTAssertNil(state.diagnostic)
    }

    func testExplicitInvalidReloadPreservesEditingStateAndExposesDiagnostic() {
        var state = OmacyEditorState(snapshot: initial)
        state.draftArt = "MY DRAFT"
        let pending = snapshot(art: "PENDING")
        state.observeExternal(pending)

        state.reload(snapshot(art: "FALLBACK", diagnostic: "art is invalid"))

        XCTAssertEqual(state.baseline, initial)
        XCTAssertEqual(state.draftArt, "MY DRAFT")
        XCTAssertEqual(state.pendingExternal, pending)
        XCTAssertEqual(state.diagnostic, "art is invalid")
    }

    func testMarkSavedPromotesNormalizedSnapshotAndClearsTransientState() {
        var state = OmacyEditorState(snapshot: initial)
        state.draftArt = "MY DRAFT"
        state.observeExternal(snapshot(art: "PENDING"))
        state.observeExternal(snapshot(art: "FALLBACK", diagnostic: "invalid"))
        let normalized = OmacyConfigSnapshot(
            settings: OmacySettings(effects: ["matrix"]),
            art: "NORMALIZED",
            diagnostic: nil,
            origin: .recoveredConfiguration
        )

        state.markSaved(normalized)

        XCTAssertEqual(state.baseline, normalized)
        XCTAssertEqual(state.draftSettings, normalized.settings)
        XCTAssertEqual(state.draftArt, "NORMALIZED")
        XCTAssertFalse(state.isDirty)
        XCTAssertNil(state.pendingExternal)
        XCTAssertNil(state.diagnostic)
    }

    func testResetDraftChangesDraftWithoutPersistingBaseline() {
        var state = OmacyEditorState(snapshot: initial)

        state.resetDraft(bundledArt: "BUNDLED")

        XCTAssertEqual(state.baseline, initial)
        XCTAssertEqual(state.draftSettings, OmacySettings())
        XCTAssertEqual(state.draftArt, "BUNDLED")
        XCTAssertTrue(state.isDirty)
    }

    func testResetDraftRemainsCleanWhenBaselineAlreadyContainsDefaultsAndBundledArt() {
        let defaults = OmacyConfigSnapshot(
            settings: OmacySettings(), art: "BUNDLED", diagnostic: nil
        )
        var state = OmacyEditorState(snapshot: defaults)

        state.resetDraft(bundledArt: "BUNDLED")

        XCTAssertEqual(state.baseline, defaults)
        XCTAssertFalse(state.isDirty)
    }

    func testAcceptPendingExternalAdoptsStagedRevision() {
        var state = OmacyEditorState(snapshot: initial)
        state.draftArt = "MY DRAFT"
        let external = snapshot(art: "EXTERNAL")
        state.observeExternal(external)

        XCTAssertTrue(state.acceptPendingExternal())

        XCTAssertEqual(state.baseline, external)
        XCTAssertEqual(state.draftArt, "EXTERNAL")
        XCTAssertFalse(state.isDirty)
        XCTAssertNil(state.pendingExternal)
        XCTAssertNil(state.diagnostic)
    }

    func testAcceptPendingExternalDoesNothingWithoutConflict() {
        var state = OmacyEditorState(snapshot: initial)

        XCTAssertFalse(state.acceptPendingExternal())
        XCTAssertEqual(state.baseline, initial)
    }

    func testAcknowledgingOverwriteClearsOnlyCurrentRevisionAndLaterChangeConflictsAgain() {
        var state = OmacyEditorState(snapshot: initial)
        state.draftArt = "MY DRAFT"
        let firstExternal = snapshot(art: "EXTERNAL 1")
        state.observeExternal(firstExternal)

        XCTAssertEqual(state.acknowledgeOverwriteOfPendingRevision(), firstExternal)
        XCTAssertNil(state.pendingExternal)
        XCTAssertEqual(state.draftArt, "MY DRAFT")

        let laterExternal = snapshot(art: "EXTERNAL 2")
        state.observeExternal(laterExternal)
        XCTAssertEqual(state.pendingExternal, laterExternal)
    }

    func testPostSaveMismatchCanStageOldBaselineAsExplicitConflict() {
        var state = OmacyEditorState(snapshot: initial)
        state.draftArt = "SAVED DRAFT"
        let recovered = OmacyConfigSnapshot(
            settings: initial.settings,
            art: initial.art,
            diagnostic: nil,
            origin: .recoveredConfiguration
        )

        state.stageExternalConflict(recovered)

        XCTAssertEqual(state.baseline, initial)
        XCTAssertEqual(state.draftArt, "SAVED DRAFT")
        XCTAssertEqual(state.pendingExternal, recovered)
        XCTAssertNil(state.diagnostic)
    }

    func testInvalidExplicitConflictPreservesEditingStateAndExistingConflict() {
        var state = OmacyEditorState(snapshot: initial)
        state.draftArt = "SAVED DRAFT"
        let pending = snapshot(art: "VALID READBACK")
        state.stageExternalConflict(pending)

        state.stageExternalConflict(snapshot(art: "FALLBACK", diagnostic: "readback is invalid"))

        XCTAssertEqual(state.baseline, initial)
        XCTAssertEqual(state.draftArt, "SAVED DRAFT")
        XCTAssertEqual(state.pendingExternal, pending)
        XCTAssertEqual(state.diagnostic, "readback is invalid")
    }

    private func snapshot(
        settings: OmacySettings = OmacySettings(effects: ["matrix"]),
        art: String,
        diagnostic: String? = nil
    ) -> OmacyConfigSnapshot {
        OmacyConfigSnapshot(settings: settings, art: art, diagnostic: diagnostic)
    }
}
