import XCTest
@testable import Omacy

@MainActor
final class OmacyWorkspaceModelTests: XCTestCase {
    private let initial = OmacyConfigSnapshot(
        settings: OmacySettings(effects: ["beams"]), art: "INITIAL", diagnostic: nil
    )

    func testInitialLoadPublishesCleanEditorAndHighlight() {
        let model = makeModel(load: { self.initial })
        XCTAssertEqual(model.editor.draftArt, "INITIAL")
        XCTAssertEqual(model.highlightedEffect, "beams")
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.operationState, .idle)
    }

    func testFreshInstallTestPersistsBootstrapDefaultsBeforePreparing() async {
        var disk = OmacyConfigSnapshot(
            settings: OmacySettings(), art: "BUNDLED", diagnostic: nil,
            origin: .bootstrapDefaults
        )
        var events: [String] = []
        let model = makeModel(
            load: { disk },
            save: { settings, art in
                events.append("save")
                disk = .init(settings: settings, art: art, diagnostic: nil)
            },
            prepare: { events.append("prepare") },
            launch: { events.append("launch") }
        )

        await model.testScreenSaver()

        XCTAssertEqual(events, ["save", "prepare", "launch"])
        XCTAssertEqual(disk.origin, .publicConfiguration)
        XCTAssertEqual(model.operationState, .idle)
    }

    func testFreshInstallCanBeSavedWithoutEditing() async {
        var disk = OmacyConfigSnapshot(
            settings: OmacySettings(), art: "BUNDLED", diagnostic: nil,
            origin: .bootstrapDefaults
        )
        var saves = 0
        let model = makeModel(load: { disk }, save: { settings, art in
            saves += 1
            disk = .init(settings: settings, art: art, diagnostic: nil)
        })

        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(saves, 1)
    }

    func testFreshInstallEditedDraftSavesWithoutFalseExternalConflict() async {
        var disk = OmacyConfigSnapshot(
            settings: OmacySettings(), art: "BUNDLED", diagnostic: nil,
            origin: .bootstrapDefaults
        )
        var savedArt: String?
        let model = makeModel(load: { disk }, save: { settings, art in
            savedArt = art
            disk = .init(settings: settings, art: art, diagnostic: nil)
        })
        model.editor.draftArt = "MY FIRST ART"

        let saved = await model.save()

        XCTAssertTrue(saved)
        XCTAssertEqual(savedArt, "MY FIRST ART")
        XCTAssertNil(model.editor.pendingExternal)
        XCTAssertEqual(model.operationState, .idle)
    }

    func testFreshInstallEditedDraftTestSavesBeforePreparing() async {
        var disk = OmacyConfigSnapshot(
            settings: OmacySettings(), art: "BUNDLED", diagnostic: nil,
            origin: .bootstrapDefaults
        )
        var events: [String] = []
        let model = makeModel(
            load: { disk },
            save: { settings, art in
                events.append("save:\(art)")
                disk = .init(settings: settings, art: art, diagnostic: nil)
            },
            prepare: { events.append("prepare") },
            launch: { events.append("launch") }
        )
        model.editor.draftArt = "MY FIRST ART"

        await model.testScreenSaver()

        XCTAssertEqual(events, ["save:MY FIRST ART", "prepare", "launch"])
        XCTAssertNil(model.editor.pendingExternal)
        XCTAssertEqual(model.operationState, .idle)
    }

    func testDefaultsStateUsesInjectedBundledArtAndDefaultSettings() {
        let defaults = OmacyConfigSnapshot(
            settings: OmacySettings(), art: "INJECTED", diagnostic: nil
        )
        let model = makeModel(load: { defaults }, bundledArt: "INJECTED")

        XCTAssertTrue(model.isAtDefaults)
        XCTAssertFalse(model.canReset)

        model.editor.draftArt = "CUSTOM"
        XCTAssertFalse(model.isAtDefaults)
        XCTAssertTrue(model.canReset)
    }

    func testDirtySaveNormalizesWritesReloadsAndMarksClean() async {
        var disk = initial
        var written: OmacyConfigSnapshot?
        let model = makeModel(
            load: { disk },
            save: { settings, art in
                written = OmacyConfigSnapshot(settings: settings, art: art, diagnostic: nil)
                disk = written!
            }
        )
        model.editor.draftSettings.effects = ["matrix"]
        model.editor.draftArt = "MINE"

        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(written?.settings.effect, "matrix")
        XCTAssertEqual(written?.art, "MINE")
        XCTAssertFalse(model.isDirty)
    }

    func testSaveStagesChangedDiskAndDoesNotWrite() async {
        var disk = initial
        var saves = 0
        let model = makeModel(load: { disk }, save: { _, _ in saves += 1 })
        model.editor.draftArt = "MINE"
        disk = snapshot("EXTERNAL")

        let saved = await model.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(model.editor.pendingExternal, disk)
        XCTAssertEqual(model.operationState, .externalConflict)
    }

    func testAcknowledgedOverwriteWritesWhenDiskStillMatchesPendingRevision() async {
        var disk = initial
        var savedArt: String?
        let model = makeModel(load: { disk }, save: { settings, art in
            savedArt = art
            disk = OmacyConfigSnapshot(settings: settings, art: art, diagnostic: nil)
        })
        model.editor.draftArt = "MINE"
        disk = snapshot("EXTERNAL")
        _ = await model.save()

        let overwritten = await model.overwriteMine()
        XCTAssertTrue(overwritten)
        XCTAssertEqual(savedArt, "MINE")
        XCTAssertFalse(model.isDirty)
    }

    func testAcknowledgedOverwriteBlocksWhenDiskChangedAgain() async {
        var disk = initial
        var saves = 0
        let model = makeModel(load: { disk }, save: { _, _ in saves += 1 })
        model.editor.draftArt = "MINE"
        disk = snapshot("EXTERNAL 1")
        _ = await model.save()
        disk = snapshot("EXTERNAL 2")

        let overwritten = await model.overwriteMine()
        XCTAssertFalse(overwritten)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(model.editor.pendingExternal, disk)
    }

    func testOverwriteAdoptsNewerDiskWhenDraftWasManuallyRevertedClean() async {
        var disk = initial
        let model = makeModel(load: { disk })
        model.editor.draftArt = "MINE"
        disk = snapshot("EXTERNAL 1")
        _ = await model.save()
        model.editor.draftSettings = initial.settings
        model.editor.draftArt = initial.art
        disk = snapshot("EXTERNAL 2")

        let overwritten = await model.overwriteMine()

        XCTAssertFalse(overwritten)
        XCTAssertEqual(model.editor.draftArt, "EXTERNAL 2")
        XCTAssertNil(model.editor.pendingExternal)
        XCTAssertEqual(model.operationState, .idle)
    }

    func testInvalidDiskBlocksSaveAndPreservesDraft() async {
        var disk = initial
        var saves = 0
        let model = makeModel(load: { disk }, save: { _, _ in saves += 1 })
        model.editor.draftArt = "MINE"
        disk = OmacyConfigSnapshot(settings: initial.settings, art: "fallback", diagnostic: "Invalid settings")

        let saved = await model.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(model.editor.draftArt, "MINE")
        XCTAssertEqual(model.operationState, .invalidFiles("Invalid settings"))
    }

    func testSaveFailurePreservesBaselineAndDraft() async {
        let model = makeModel(load: { self.initial }, save: { _, _ in throw TestError.failed })
        model.editor.draftArt = "MINE"

        let saved = await model.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(model.editor.baseline, initial)
        XCTAssertEqual(model.editor.draftArt, "MINE")
        XCTAssertEqual(model.operationState, .error("Your changes weren't saved."))
    }

    func testMismatchedReadbackAfterSavePreservesDraftAndFailsVerification() async {
        var disk = initial
        let model = makeModel(load: { disk }, save: { _, _ in disk = self.snapshot("STALE") })
        model.editor.draftArt = "MINE"

        let saved = await model.save()

        XCTAssertFalse(saved)
        XCTAssertEqual(model.editor.baseline, initial)
        XCTAssertEqual(model.editor.draftArt, "MINE")
        XCTAssertEqual(model.editor.pendingExternal, disk)
        XCTAssertEqual(model.operationState, .externalConflict)

        disk = snapshot("CHANGED AGAIN")
        let overwritten = await model.overwriteMine()
        XCTAssertFalse(overwritten)
        XCTAssertEqual(model.editor.pendingExternal, disk)
    }

    func testCleanSaveAdoptsChangedDiskWithoutFalseConflict() async {
        var disk = initial
        let model = makeModel(load: { disk }, save: { settings, art in
            disk = .init(settings: settings, art: art, diagnostic: nil)
        })
        disk = snapshot("EXTERNAL")

        let saved = await model.save()

        XCTAssertTrue(saved)
        XCTAssertEqual(model.editor.draftArt, "EXTERNAL")
        XCTAssertEqual(model.operationState, .idle)
    }

    func testActivationRefreshAdoptsCleanExternalAndDiagnosesInvalid() {
        var disk = snapshot("EXTERNAL")
        let model = makeModel(load: { disk })
        disk = snapshot("NEW")
        model.refreshFromDisk()
        XCTAssertEqual(model.editor.draftArt, "NEW")

        disk = OmacyConfigSnapshot(settings: initial.settings, art: "fallback", diagnostic: "Invalid art")
        model.refreshFromDisk()
        XCTAssertEqual(model.editor.draftArt, "NEW")
        XCTAssertEqual(model.operationState, .invalidFiles("Invalid art"))
    }

    func testReloadExternalAcceptsConflict() async {
        var disk = initial
        let model = makeModel(load: { disk })
        model.editor.draftArt = "MINE"
        disk = snapshot("EXTERNAL")
        _ = await model.save()

        model.reloadExternal()
        XCTAssertEqual(model.editor.draftArt, "EXTERNAL")
        XCTAssertFalse(model.isDirty)
    }

    func testResetIsDraftOnlyAndClearsStagedImage() {
        let model = makeModel(load: { self.initial }, bundledArt: "BUNDLED", convert: { _, _ in "CONVERTED" })
        model.importImage(Data([1]))
        model.resetDraft()
        XCTAssertEqual(model.editor.baseline, initial)
        XCTAssertEqual(model.editor.draftArt, "BUNDLED")
        XCTAssertFalse(model.canReconvert)
    }

    func testResetKeepsExistingExternalConflictVisible() async {
        var disk = initial
        let model = makeModel(load: { disk })
        model.editor.draftArt = "MINE"
        disk = snapshot("EXTERNAL")
        _ = await model.save()

        model.resetDraft()

        XCTAssertEqual(model.editor.pendingExternal, disk)
        XCTAssertEqual(model.operationState, .externalConflict)
    }

    func testDiscardRestoresBaselineAndDisarmsImportedImage() {
        var conversions = 0
        let model = makeModel(load: { self.initial }, convert: { _, _ in
            conversions += 1
            return "CONVERTED \(conversions)"
        })
        model.importImage(Data([1]))

        model.discardDraft()
        model.reconvertStagedImage()

        XCTAssertEqual(model.editor.draftSettings, initial.settings)
        XCTAssertEqual(model.editor.draftArt, "INITIAL")
        XCTAssertFalse(model.canReconvert)
        XCTAssertEqual(conversions, 1)
        XCTAssertFalse(model.isDirty)
    }

    func testDiscardPreservesPendingExternalConflictForExplicitResolution() async {
        var disk = initial
        let model = makeModel(load: { disk })
        model.editor.draftArt = "MINE"
        disk = snapshot("EXTERNAL")
        _ = await model.save()

        model.discardDraft()

        XCTAssertEqual(model.editor.draftArt, "INITIAL")
        XCTAssertEqual(model.editor.pendingExternal, disk)
        XCTAssertEqual(model.operationState, .externalConflict)
    }

    func testRevertingDraftToBaselineAndRefreshingAdoptsPendingExternal() async {
        var disk = initial
        let model = makeModel(load: { disk })
        model.editor.draftArt = "MINE"
        disk = snapshot("EXTERNAL")
        _ = await model.save()
        model.editor.draftArt = initial.art
        model.editor.draftSettings = initial.settings

        model.refreshFromDisk()

        XCTAssertEqual(model.editor.draftArt, "EXTERNAL")
        XCTAssertNil(model.editor.pendingExternal)
        XCTAssertEqual(model.operationState, .idle)
    }

    func testImportForcesBlockModeAndReconvertUsesStagedData() {
        var conversions = 0
        let model = makeModel(load: { self.initial }, convert: { _, settings in
            conversions += 1
            return "\(settings.asciiMode)-\(conversions)"
        })
        model.editor.draftSettings.asciiMode = "braille"
        model.importImage(Data([1]))
        XCTAssertEqual(model.editor.draftArt, "block-1")
        model.reconvertStagedImage()
        XCTAssertEqual(model.editor.draftArt, "block-2")
        XCTAssertTrue(model.canReconvert)
    }

    func testFailedImportRetainsDraftAndSurfacesError() {
        let model = makeModel(load: { self.initial }, convert: { _, _ in throw TestError.failed })
        model.importImage(Data([1]))
        XCTAssertEqual(model.editor.draftArt, "INITIAL")
        XCTAssertEqual(model.conversionError, "The image couldn't be converted.")
        XCTAssertEqual(model.operationState, .idle)
        XCTAssertTrue(model.canReconvert)
    }

    func testDirtyTestRunsSaveThenPrepareThenLaunch() async {
        var disk = initial
        var events: [String] = []
        let model = makeModel(
            load: { disk },
            save: { settings, art in events.append("save"); disk = .init(settings: settings, art: art, diagnostic: nil) },
            prepare: { events.append("prepare") }, launch: { events.append("launch") }
        )
        model.editor.draftArt = "MINE"
        await model.testScreenSaver()
        XCTAssertEqual(events, ["save", "prepare", "launch"])
    }

    func testCleanTestSkipsSave() async {
        var events: [String] = []
        let model = makeModel(load: { self.initial }, save: { _, _ in events.append("save") },
                              prepare: { events.append("prepare") }, launch: { events.append("launch") })
        await model.testScreenSaver()
        XCTAssertEqual(events, ["prepare", "launch"])
    }

    func testPrepareAndLaunchFailuresStopSubsequentActions() async {
        var events: [String] = []
        let prepareFailure = makeModel(load: { self.initial }, prepare: {
            events.append("prepare"); throw TestError.failed
        }, launch: { events.append("launch") })
        await prepareFailure.testScreenSaver()
        XCTAssertEqual(events, ["prepare"])
        XCTAssertEqual(prepareFailure.operationState, .error("Omacy couldn't be made ready for testing."))
        XCTAssertFalse(prepareFailure.isBusy)

        events = []
        let launchFailure = makeModel(load: { self.initial }, prepare: { events.append("prepare") },
                                      launch: { events.append("launch"); throw TestError.failed })
        await launchFailure.testScreenSaver()
        XCTAssertEqual(events, ["prepare", "launch"])
        XCTAssertEqual(launchFailure.operationState, .error("macOS couldn't start the screen saver."))
        XCTAssertFalse(launchFailure.isBusy)
    }

    func testCleanTestRefreshesAndAdoptsExternalBeforePreparing() async {
        var disk = initial
        var preparedArt: String?
        var model: OmacyWorkspaceModel!
        model = makeModel(load: { disk }, prepare: { preparedArt = model.editor.draftArt })
        disk = snapshot("EXTERNAL")

        await model.testScreenSaver()

        XCTAssertEqual(preparedArt, "EXTERNAL")
        XCTAssertEqual(model.editor.draftArt, "EXTERNAL")
    }

    func testInvalidExternalConfigurationStopsTestBeforePrepare() async {
        var disk = initial
        var prepares = 0
        let model = makeModel(load: { disk }, prepare: { prepares += 1 })
        disk = .init(settings: initial.settings, art: "fallback", diagnostic: "Invalid art")

        await model.testScreenSaver()

        XCTAssertEqual(prepares, 0)
        XCTAssertEqual(model.operationState, .invalidFiles("Invalid art"))
    }

    func testReloadExternalWithoutConflictDoesNotDiscardDirtyDraft() {
        let model = makeModel(load: { self.initial })
        model.editor.draftArt = "MINE"

        model.reloadExternal()

        XCTAssertEqual(model.editor.draftArt, "MINE")
        XCTAssertTrue(model.isDirty)
    }

    func testBusyGuardPreventsDuplicateTestAction() async {
        let started = AsyncGate()
        let release = AsyncGate()
        var prepares = 0
        let model = makeModel(load: { self.initial }, prepare: {
            prepares += 1
            await started.open()
            await release.wait()
        })
        let first = Task { await model.testScreenSaver() }
        await started.wait()
        await model.testScreenSaver()
        XCTAssertEqual(prepares, 1)
        await release.open()
        await first.value
    }

    func testBusyGuardAlsoPreventsPublicSaveAndOverwrite() async {
        let started = AsyncGate()
        let release = AsyncGate()
        var saves = 0
        let model = makeModel(load: { self.initial }, save: { _, _ in saves += 1 }, prepare: {
            await started.open()
            await release.wait()
        })
        let test = Task { await model.testScreenSaver() }
        await started.wait()

        let saved = await model.save()
        let overwritten = await model.overwriteMine()

        XCTAssertFalse(saved)
        XCTAssertFalse(overwritten)
        XCTAssertEqual(saves, 0)
        await release.open()
        await test.value
    }

    func testInvalidDiskAtLaunchReportsInvalidFilesState() {
        let model = makeModel(load: {
            OmacyConfigSnapshot(
                settings: self.initial.settings, art: "fallback",
                diagnostic: "Invalid settings", origin: .recoveredConfiguration
            )
        })

        XCTAssertEqual(model.operationState, .invalidFiles("Invalid settings"))
    }

    func testReplaceInvalidFilesWritesDraftReloadsAndClearsState() async {
        var disk = OmacyConfigSnapshot(
            settings: initial.settings, art: "fallback",
            diagnostic: "Invalid settings", origin: .recoveredConfiguration
        )
        var written: OmacyConfigSnapshot?
        let model = makeModel(load: { disk }, save: { settings, art in
            written = OmacyConfigSnapshot(settings: settings, art: art, diagnostic: nil)
            disk = written!
        })
        model.editor.draftArt = "MINE"

        let replaced = await model.replaceInvalidFiles()

        XCTAssertTrue(replaced)
        XCTAssertEqual(written?.art, "MINE")
        XCTAssertEqual(model.editor.draftArt, "MINE")
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.operationState, .idle)
        XCTAssertFalse(model.isBusy)
    }

    func testReplaceInvalidFilesKeepsInvalidStateWhenFilesStayInvalid() async {
        let stillInvalid = OmacyConfigSnapshot(
            settings: initial.settings, art: "fallback",
            diagnostic: "settings.json is invalid", origin: .recoveredConfiguration
        )
        var saves = 0
        let model = makeModel(load: { stillInvalid }, save: { _, _ in saves += 1 })
        model.editor.draftArt = "MINE"

        let replaced = await model.replaceInvalidFiles()

        XCTAssertFalse(replaced)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(model.editor.draftArt, "MINE")
        XCTAssertEqual(model.operationState, .invalidFiles("settings.json is invalid"))
    }

    func testReplaceInvalidFilesStagesConflictWhenReadbackMismatches() async {
        var disk = OmacyConfigSnapshot(
            settings: initial.settings, art: "fallback",
            diagnostic: "Invalid settings", origin: .recoveredConfiguration
        )
        let model = makeModel(load: { disk }, save: { _, _ in disk = self.snapshot("STALE") })
        model.editor.draftArt = "MINE"

        let replaced = await model.replaceInvalidFiles()

        XCTAssertFalse(replaced)
        XCTAssertEqual(model.editor.draftArt, "MINE")
        XCTAssertEqual(model.editor.pendingExternal, disk)
        XCTAssertEqual(model.operationState, .externalConflict)
    }

    func testReplaceInvalidFilesIsNoOpWhenFilesAreValid() async {
        var saves = 0
        let model = makeModel(load: { self.initial }, save: { _, _ in saves += 1 })
        model.editor.draftArt = "MINE"

        let replaced = await model.replaceInvalidFiles()

        XCTAssertFalse(replaced)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(model.operationState, .idle)
    }

    func testFailedConversionKeepsInvalidFilesStateVisible() {
        let model = makeModel(load: {
            OmacyConfigSnapshot(
                settings: self.initial.settings, art: "fallback",
                diagnostic: "Invalid settings", origin: .recoveredConfiguration
            )
        }, convert: { _, _ in throw TestError.failed })

        model.importImage(Data([1]))

        XCTAssertEqual(model.conversionError, "The image couldn't be converted.")
        XCTAssertEqual(model.operationState, .invalidFiles("Invalid settings"))
    }

    func testFailedConversionKeepsExternalConflictVisible() async {
        var disk = initial
        let model = makeModel(load: { disk }, convert: { _, _ in throw TestError.failed })
        model.editor.draftArt = "MINE"
        disk = snapshot("EXTERNAL")
        _ = await model.save()

        model.importImage(Data([1]))

        XCTAssertEqual(model.conversionError, "The image couldn't be converted.")
        XCTAssertEqual(model.operationState, .externalConflict)
    }

    func testSuccessfulConversionKeepsInvalidFilesStateVisible() {
        let model = makeModel(load: {
            OmacyConfigSnapshot(
                settings: self.initial.settings, art: "fallback",
                diagnostic: "Invalid settings", origin: .recoveredConfiguration
            )
        }, convert: { _, _ in "CONVERTED" })

        model.importImage(Data([1]))

        XCTAssertEqual(model.editor.draftArt, "CONVERTED")
        XCTAssertEqual(model.operationState, .invalidFiles("Invalid settings"))
    }

    func testSuccessfulConversionKeepsExternalConflictVisible() async {
        var disk = initial
        let model = makeModel(load: { disk }, convert: { _, _ in "CONVERTED" })
        model.editor.draftArt = "MINE"
        disk = snapshot("EXTERNAL")
        _ = await model.save()

        model.importImage(Data([1]))

        XCTAssertEqual(model.editor.draftArt, "CONVERTED")
        XCTAssertEqual(model.operationState, .externalConflict)
    }

    func testSuccessfulConversionClearsPreviousConversionFailure() {
        var failNext = true
        let model = makeModel(load: { self.initial }, convert: { _, _ in
            if failNext { throw TestError.failed }
            return "CONVERTED"
        })
        model.importImage(Data([1]))
        XCTAssertEqual(model.conversionError, "The image couldn't be converted.")

        failNext = false
        model.reconvertStagedImage()

        XCTAssertEqual(model.editor.draftArt, "CONVERTED")
        XCTAssertNil(model.conversionError)
        XCTAssertEqual(model.operationState, .idle)
    }

    func testDiscardAndResetClearConversionError() {
        let model = makeModel(load: { self.initial }, convert: { _, _ in throw TestError.failed })
        model.importImage(Data([1]))
        model.discardDraft()
        XCTAssertNil(model.conversionError)

        model.importImage(Data([1]))
        model.resetDraft()
        XCTAssertNil(model.conversionError)
    }

    func testReplaceInvalidFilesWritesNothingWhenDiskHealedFirst() async {
        var disk = OmacyConfigSnapshot(
            settings: initial.settings, art: "fallback",
            diagnostic: "Invalid settings", origin: .recoveredConfiguration
        )
        var saves = 0
        let model = makeModel(load: { disk }, save: { _, _ in saves += 1 })
        disk = snapshot("HEALED")

        let replaced = await model.replaceInvalidFiles()

        XCTAssertFalse(replaced)
        XCTAssertEqual(saves, 0)
        XCTAssertFalse(model.hasInvalidFiles)
        XCTAssertEqual(model.operationState, .idle)
        XCTAssertEqual(model.editor.draftArt, "HEALED")
    }

    func testReplaceInvalidFilesOverwritesBothFilesWithTheDraft() async {
        var disk = OmacyConfigSnapshot(
            settings: initial.settings, art: "NEWER EXTERNAL ART",
            diagnostic: "settings.json is invalid; using last-known-good settings",
            origin: .recoveredConfiguration
        )
        var written: OmacyConfigSnapshot?
        let model = makeModel(load: { disk }, save: { settings, art in
            written = OmacyConfigSnapshot(settings: settings, art: art, diagnostic: nil)
            disk = written!
        })
        model.editor.draftArt = "MINE"

        let replaced = await model.replaceInvalidFiles()

        XCTAssertTrue(replaced)
        XCTAssertEqual(written?.art, "MINE")
        XCTAssertEqual(written?.settings, model.editor.draftSettings)
        XCTAssertEqual(model.operationState, .idle)
    }

    func testPersistFailureDuringReplaceKeepsRecoveryReachable() async {
        let model = makeModel(load: {
            OmacyConfigSnapshot(
                settings: self.initial.settings, art: "fallback",
                diagnostic: "Invalid settings", origin: .recoveredConfiguration
            )
        }, save: { _, _ in throw TestError.failed })

        let replaced = await model.replaceInvalidFiles()

        XCTAssertFalse(replaced)
        XCTAssertEqual(model.operationState, .error("Your changes weren't saved."))
        XCTAssertTrue(model.hasInvalidFiles)
    }

    func testBusyGuardPreventsConcurrentReplaceInvalidFiles() async {
        let started = AsyncGate()
        let release = AsyncGate()
        var saves = 0
        let model = makeModel(load: { self.initial }, save: { _, _ in saves += 1 }, prepare: {
            await started.open()
            await release.wait()
        })
        let test = Task { await model.testScreenSaver() }
        await started.wait()
        model.editor.observeExternal(OmacyConfigSnapshot(
            settings: initial.settings, art: "fallback",
            diagnostic: "Invalid settings", origin: .recoveredConfiguration
        ))
        XCTAssertTrue(model.hasInvalidFiles)

        let replaced = await model.replaceInvalidFiles()

        XCTAssertFalse(replaced)
        XCTAssertEqual(saves, 0)
        await release.open()
        await test.value
    }

    func testActivationRefreshKeepsUnresolvedSaveFailureVisible() async {
        let model = makeModel(load: { self.initial }, save: { _, _ in throw TestError.failed })
        model.editor.draftArt = "MINE"
        _ = await model.save()
        XCTAssertEqual(model.operationState, .error("Your changes weren't saved."))

        model.refreshFromDisk()

        XCTAssertEqual(model.operationState, .error("Your changes weren't saved."))
        XCTAssertEqual(model.editor.draftArt, "MINE")
    }

    func testRetryingSaveClearsPreviousFailureBeforeWriting() async {
        var disk = initial
        var failNext = true
        let model = makeModel(load: { disk }, save: { settings, art in
            if failNext { throw TestError.failed }
            disk = .init(settings: settings, art: art, diagnostic: nil)
        })
        model.editor.draftArt = "MINE"
        _ = await model.save()
        XCTAssertEqual(model.operationState, .error("Your changes weren't saved."))

        failNext = false
        let saved = await model.save()

        XCTAssertTrue(saved)
        XCTAssertEqual(model.operationState, .idle)
    }

    func testTestScreenSaverClearsPreviousFailureAndProceeds() async {
        var events: [String] = []
        var failPrepare = true
        let model = makeModel(load: { self.initial }, prepare: {
            events.append("prepare")
            if failPrepare { throw TestError.failed }
        }, launch: { events.append("launch") })
        await model.testScreenSaver()
        XCTAssertEqual(model.operationState, .error("Omacy couldn't be made ready for testing."))

        failPrepare = false
        await model.testScreenSaver()

        XCTAssertEqual(events, ["prepare", "prepare", "launch"])
        XCTAssertEqual(model.operationState, .idle)
    }

    private func snapshot(_ art: String) -> OmacyConfigSnapshot {
        OmacyConfigSnapshot(settings: OmacySettings(effects: ["matrix"]), art: art, diagnostic: nil)
    }

    private func makeModel(
        load: @escaping () -> OmacyConfigSnapshot,
        save: @escaping (OmacySettings, String) throws -> Void = { _, _ in },
        bundledArt: String = "BUNDLED",
        convert: @escaping (Data, OmacySettings) throws -> String = { _, _ in "CONVERTED" },
        prepare: @escaping () async throws -> Void = {},
        launch: @escaping () async throws -> Void = {}
    ) -> OmacyWorkspaceModel {
        OmacyWorkspaceModel(load: load, save: save, bundledArt: bundledArt,
                            convert: convert, prepareForTest: prepare, launch: launch)
    }
}

private enum TestError: Error { case failed }

private actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}
