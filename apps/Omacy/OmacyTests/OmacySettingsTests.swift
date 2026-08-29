import XCTest
import Darwin
@testable import Omacy

final class OmacySettingsTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmacyConfigTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testDecodeSettingsUsesDefaultsForMissingFields() throws {
        let decoded = OmacyStore.decodeSettings(try json([:]), lastGood: OmacySettings(background: "#123456"))

        XCTAssertEqual(decoded.settings, OmacySettings())
        XCTAssertNil(decoded.error)
    }

    func testDecodeSettingsKeepsLastKnownGoodForMalformedJSON() {
        let lastGood = OmacySettings(effect: "wipe", effects: ["wipe"], background: "#123456")

        let decoded = OmacyStore.decodeSettings(Data("{".utf8), lastGood: lastGood)

        XCTAssertEqual(decoded.settings, lastGood)
        XCTAssertEqual(decoded.error, "Could not read settings.json; keeping last-known-good")
    }

    func testDecodeSettingsKeepsLastKnownGoodForNonObjectJSON() throws {
        let lastGood = OmacySettings(effect: "wipe", effects: ["wipe"])

        let decoded = OmacyStore.decodeSettings(try JSONSerialization.data(withJSONObject: ["wipe"]), lastGood: lastGood)

        XCTAssertEqual(decoded.settings, lastGood)
        XCTAssertEqual(decoded.error, "settings.json is invalid; keeping last-known-good")
    }

    func testDecodeSettingsSupportsLegacyNamedEffect() throws {
        let decoded = OmacyStore.decodeSettings(try json(["effect": "wipe"]), lastGood: OmacySettings())

        XCTAssertEqual(decoded.settings.effect, "wipe")
        XCTAssertEqual(decoded.settings.effects, ["wipe"])
        XCTAssertNil(decoded.error)
    }

    func testDecodeSettingsSanitizesEffectListAndReadsAllFields() throws {
        let data = try json([
            "effect": "random",
            "effects": ["wipe", "unknown", "beams", "wipe"],
            "background": "#123456",
            "fontSize": 24.0,
            "asciiMode": "braille",
            "threshold": 75,
            "invert": true,
        ])

        let decoded = OmacyStore.decodeSettings(data, lastGood: OmacySettings())

        XCTAssertEqual(decoded.settings.effect, "random")
        XCTAssertEqual(decoded.settings.effects, ["beams", "wipe"])
        XCTAssertEqual(decoded.settings.background, "#123456")
        XCTAssertEqual(decoded.settings.fontSize, 24)
        XCTAssertEqual(decoded.settings.asciiMode, "braille")
        XCTAssertEqual(decoded.settings.threshold, 75)
        XCTAssertTrue(decoded.settings.invert)
        XCTAssertNil(decoded.error)
    }

    func testSanitizeDropsUnknownAndDuplicateEffectsWhileKeepingOrder() {
        XCTAssertEqual(OmacyEffects.sanitize(["wipe", "unknown", "beams", "wipe"]), ["wipe", "beams"])
    }

    func testSchemaValidationUsesInjectedEngineCatalog() throws {
        let catalog = OmacyEffectCatalog(names: ["custom-one", "custom-two"])
        let accepted = try json(["effect": "custom-one", "effects": ["custom-two"]])
        let rejected = try json(["effect": "wipe"])

        XCTAssertNotNil(OmacySettingsCodec.decodeValidated(accepted, catalog: catalog))
        XCTAssertNil(OmacySettingsCodec.decodeValidated(rejected, catalog: catalog))
        XCTAssertEqual(
            OmacyEffects.sanitize(["custom-two", "wipe"], catalog: catalog),
            ["custom-two"]
        )
    }

    func testSyncEngineEffectUsesSingleSelectedEffect() {
        var settings = OmacySettings(effects: ["wipe"])
        settings.syncEngineEffect()
        XCTAssertEqual(settings.effects, ["wipe"])
        XCTAssertEqual(settings.effect, "wipe")
    }

    func testSyncEngineEffectRestoresAllEffectsForEmptySelection() {
        var settings = OmacySettings(effects: [])
        settings.syncEngineEffect()
        XCTAssertEqual(settings.effects, OmacyEffects.names)
        XCTAssertEqual(settings.effect, "random")
    }

    func testBackgroundRGBAParsesSixDigitHex() {
        let rgba = OmacySettings(background: "#1a2B3c").backgroundRGBA
        XCTAssertEqual(rgba.0, 0x1A); XCTAssertEqual(rgba.1, 0x2B)
        XCTAssertEqual(rgba.2, 0x3C); XCTAssertEqual(rgba.3, 0xFF)
    }

    func testBackgroundRGBAFallsBackToOpaqueBlackForInvalidInput() {
        let rgba = OmacySettings(background: "not-a-color").backgroundRGBA
        XCTAssertEqual(rgba.0, 0); XCTAssertEqual(rgba.1, 0)
        XCTAssertEqual(rgba.2, 0); XCTAssertEqual(rgba.3, 255)
    }

    func testLivePathsUseLoginHomeForPublicConfigAndApplicationSupportForPrivateCache() {
        let loginHome = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!

        let paths = OmacyConfigPaths.live(loginHomeDirectory: { loginHome })

        XCTAssertEqual(paths.configDirectory.path, "/Users/example/.config/omacy")
        XCTAssertEqual(
            paths.cacheDirectory,
            applicationSupport.appendingPathComponent("Omacy/LastGoodConfig", isDirectory: true)
        )
    }

    func testLoginHomeDirectoryMatchesCurrentUnixAccount() throws {
        let passwordRecord = try XCTUnwrap(getpwuid(getuid()))
        let expectedPath = String(cString: try XCTUnwrap(passwordRecord.pointee.pw_dir))

        XCTAssertEqual(OmacyLoginHomeDirectory.current().path, expectedPath)
    }

    func testUpdateRecoveryRegistersBeforeRestartingAndThenRecordsIdentity() throws {
        var events: [String] = []
        let recovery = OmacyUpdateRecovery(
            currentIdentity: "0.1.3:45",
            storedIdentity: { "0.1.2:44" },
            isActiveScreensaver: { true },
            registerExtension: { events.append("register") },
            restartWallpaperAgent: { events.append("restart") },
            recordIdentity: { events.append("record:\($0)") }
        )

        try recovery.reconcile()

        XCTAssertEqual(events, ["register", "restart", "record:0.1.3:45"])
    }

    func testUpdateRecoveryRecordsInactiveBootstrapWithoutRestartingServices() throws {
        var events: [String] = []
        let recovery = OmacyUpdateRecovery(
            currentIdentity: "0.1.3:45",
            storedIdentity: { nil },
            isActiveScreensaver: { false },
            registerExtension: { events.append("register") },
            restartWallpaperAgent: { events.append("restart") },
            recordIdentity: { events.append("record:\($0)") }
        )

        try recovery.reconcile()

        XCTAssertEqual(events, ["record:0.1.3:45"])
    }

    func testUpdateRecoveryDoesNotRecordFailedReconciliation() {
        var recordedIdentity: String?
        let recovery = OmacyUpdateRecovery(
            currentIdentity: "0.1.3:45",
            storedIdentity: { "0.1.2:44" },
            isActiveScreensaver: { true },
            registerExtension: { throw CocoaError(.fileNoSuchFile) },
            restartWallpaperAgent: {},
            recordIdentity: { recordedIdentity = $0 }
        )

        XCTAssertThrowsError(try recovery.reconcile())
        XCTAssertNil(recordedIdentity)
    }

    func testRepositoryCombinesLatestIndividuallyValidPublicFiles() throws {
        let repository = makeRepository()
        try repository.save(settings: OmacySettings(background: "#112233"), art: "FIRST")
        try Data("{".utf8).write(to: repository.paths.settingsURL)
        try Data("SECOND".utf8).write(to: repository.paths.artURL)

        let snapshot = repository.load()

        XCTAssertEqual(snapshot.settings.background, "#112233")
        XCTAssertEqual(snapshot.art, "SECOND")
        XCTAssertEqual(snapshot.diagnostic, "settings.json is invalid; using last-known-good settings")
    }

    func testColdRepositoryUsesCacheWhenPublicFilesAreInvalid() throws {
        let first = makeRepository()
        try first.save(settings: OmacySettings(background: "#abcdef"), art: "CACHED")
        try Data("{".utf8).write(to: first.paths.settingsURL)
        try Data().write(to: first.paths.artURL)

        let snapshot = makeRepository().load()

        XCTAssertEqual(snapshot.settings.background, "#abcdef")
        XCTAssertEqual(snapshot.art, "CACHED")
        XCTAssertEqual(snapshot.diagnostic, "Public configuration is invalid; using private last-known-good cache")
    }

    func testColdRepositoryUsesBundledFallbackWithoutValidPublicOrCache() throws {
        let repository = makeRepository()
        try FileManager.default.createDirectory(at: repository.paths.configDirectory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: repository.paths.settingsURL)
        try Data().write(to: repository.paths.artURL)

        let snapshot = repository.load()

        XCTAssertEqual(snapshot.settings, OmacySettings())
        XCTAssertEqual(snapshot.art, "BUNDLED")
        XCTAssertEqual(snapshot.diagnostic, "No valid public or cached configuration; using bundled defaults")
    }

    func testSaveUsesReplaceableFilesAndLeavesNoTemporaryFiles() throws {
        let repository = makeRepository()
        try repository.save(settings: OmacySettings(background: "#123456"), art: "ONE")
        try repository.save(settings: OmacySettings(background: "#654321"), art: "TWO")

        XCTAssertEqual(repository.load().art, "TWO")
        XCTAssertEqual(repository.load().settings.background, "#654321")
        let names = try FileManager.default.contentsOfDirectory(atPath: repository.paths.configDirectory.path)
        XCTAssertFalse(names.contains(where: { $0.hasSuffix(".tmp") }))
    }

    func testAgentAtomicRenameIsObservedOnNextRepositoryLoad() throws {
        let repository = makeRepository()
        try repository.save(settings: OmacySettings(effects: ["wipe"]), art: "BEFORE")

        let settingsTemporary = repository.paths.configDirectory.appendingPathComponent(".agent-settings.tmp")
        let artTemporary = repository.paths.configDirectory.appendingPathComponent(".agent-art.tmp")
        try json(["effect": "beams", "effects": ["beams"]]).write(to: settingsTemporary)
        try Data("AGENT ART\n".utf8).write(to: artTemporary)
        _ = try FileManager.default.replaceItemAt(repository.paths.settingsURL, withItemAt: settingsTemporary)
        _ = try FileManager.default.replaceItemAt(repository.paths.artURL, withItemAt: artTemporary)

        var boundaryLoads = 0
        let snapshot = OmacyBoundaryConfiguration.resolve(
            isPinned: false,
            current: .init(settings: OmacySettings(effects: ["wipe"]), art: "BEFORE", diagnostic: nil),
            load: { boundaryLoads += 1; return repository.load() }
        )
        XCTAssertEqual(boundaryLoads, 1, "External writers require a public-file read at the boundary")
        XCTAssertEqual(snapshot.settings.effects, ["beams"])
        XCTAssertEqual(snapshot.art, "AGENT ART\n")
    }

    func testPinnedPreviewDoesNotReloadAgentFilesAtBoundary() {
        let current = OmacyConfigSnapshot(
            settings: OmacySettings(effects: ["wipe"]), art: "PINNED", diagnostic: nil
        )
        var loaded = false

        let snapshot = OmacyBoundaryConfiguration.resolve(
            isPinned: true,
            current: current,
            load: { loaded = true; return current }
        )

        XCTAssertEqual(snapshot, current)
        XCTAssertFalse(loaded)
    }

    func testAtomicWriteFailurePreservesExistingDestinations() throws {
        let repository = makeRepository()
        try repository.save(settings: OmacySettings(background: "#123456"), art: "ORIGINAL")
        let failing = makeRepository(atomicWrite: { _, _ in throw CocoaError(.fileWriteNoPermission) })

        XCTAssertThrowsError(try failing.save(
            settings: OmacySettings(background: "#ffffff"),
            art: "REPLACEMENT"
        ))

        let snapshot = makeRepository().load()
        XCTAssertEqual(snapshot.settings.background, "#123456")
        XCTAssertEqual(snapshot.art, "ORIGINAL")
    }

    func testSecondIndependentWriteFailurePublishesSettingsAndPreservesArt() throws {
        let repository = makeRepository()
        try repository.save(settings: OmacySettings(background: "#123456"), art: "ORIGINAL")
        var writeCount = 0
        let secondWriteFails = makeRepository(atomicWrite: { data, url in
            writeCount += 1
            if writeCount == 2 { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })

        XCTAssertThrowsError(try secondWriteFails.save(
            settings: OmacySettings(background: "#ffffff"),
            art: "REPLACEMENT"
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("screensaver.txt"))
            XCTAssertTrue(error.localizedDescription.contains("Settings were saved"))
        }

        // The two canonical files are intentionally independent publications.
        let snapshot = makeRepository().load()
        XCTAssertEqual(snapshot.settings.background, "#ffffff")
        XCTAssertEqual(snapshot.art, "ORIGINAL")
    }

    func testSemanticallyInvalidSettingsPreserveLastKnownGood() throws {
        let invalidObjects: [[String: Any]] = [
            ["effect": "not-an-effect"],
            ["effects": ["wipe", "wipe"]],
            ["effects": ["wipe", "not-an-effect"]],
            ["background": "red"],
            ["fontSize": 0],
            ["asciiMode": "pixels"],
            ["threshold": -1],
            ["threshold": 101],
            ["invert": "yes"],
        ]

        for object in invalidObjects {
            let repository = makeRepository()
            try repository.save(settings: OmacySettings(background: "#123456"), art: "ART")
            try json(object).write(to: repository.paths.settingsURL)

            XCTAssertEqual(repository.load().settings.background, "#123456", "Expected rejection: \(object)")
        }
    }

    func testArtSchemaMatchesRustLimitsAndEscapeRules() {
        XCTAssertNil(OmacyArtSchema.validationError(for: "ASCII\tcontrol\0is accepted"))
        XCTAssertNil(OmacyArtSchema.validationError(for: "Unicode: café 👋"))
        XCTAssertNil(OmacyArtSchema.validationError(for: String(repeating: "界", count: 256)))

        XCTAssertEqual(OmacyArtSchema.validationError(for: ""), "ASCII art is empty")
        XCTAssertEqual(
            OmacyArtSchema.validationError(for: "unsafe\u{001B}[31m"),
            "ASCII art must not contain ESC"
        )
        XCTAssertEqual(
            OmacyArtSchema.validationError(for: String(repeating: "x", count: 65_537)),
            "ASCII input exceeds 64 KiB"
        )
        XCTAssertEqual(
            OmacyArtSchema.validationError(for: Array(repeating: "x", count: 129).joined(separator: "\n")),
            "ASCII line count exceeds 128"
        )
        XCTAssertEqual(
            OmacyArtSchema.validationError(for: String(repeating: "x", count: 257)),
            "ASCII column count exceeds 256"
        )
    }

    func testInvalidPublicArtNeverReplacesPrivateLastGoodCache() throws {
        let invalidArt: [Data] = [
            Data("unsafe\u{001B}[31m".utf8),
            Data(String(repeating: "x", count: 65_537).utf8),
            Data(Array(repeating: "x", count: 129).joined(separator: "\n").utf8),
            Data(String(repeating: "x", count: 257).utf8),
            Data([0xFF, 0xFE]),
        ]

        for (index, invalid) in invalidArt.enumerated() {
            let directory = temporaryDirectory.appendingPathComponent("case-\(index)", isDirectory: true)
            let paths = OmacyConfigPaths(
                configDirectory: directory.appendingPathComponent("public", isDirectory: true),
                cacheDirectory: directory.appendingPathComponent("private", isDirectory: true),
                migrationMarkerURL: directory.appendingPathComponent("migration-attempted")
            )
            let repository = OmacyConfigRepository(paths: paths, bundledArt: { "BUNDLED" })
            try repository.save(settings: OmacySettings(), art: "LAST GOOD")
            try invalid.write(to: paths.artURL)

            let coldSnapshot = OmacyConfigRepository(paths: paths, bundledArt: { "BUNDLED" }).load()
            XCTAssertEqual(coldSnapshot.art, "LAST GOOD", "case \(index)")
            XCTAssertEqual(
                try String(contentsOf: paths.cachedArtURL, encoding: .utf8),
                "LAST GOOD",
                "case \(index)"
            )
        }
    }

    func testSaveRejectsInvalidArtBeforePublishingSettings() throws {
        let repository = makeRepository()
        try repository.save(settings: OmacySettings(background: "#123456"), art: "ORIGINAL")

        XCTAssertThrowsError(try repository.save(
            settings: OmacySettings(background: "#ffffff"),
            art: "unsafe\u{001B}[31m"
        ))

        let snapshot = makeRepository().load()
        XCTAssertEqual(snapshot.settings.background, "#123456")
        XCTAssertEqual(snapshot.art, "ORIGINAL")
    }

    func testOversizeSparseNonregularAndSymlinkArtPreserveLastGood() throws {
        try assertRejectedArtNodePreservesCache { url in
            try Data(repeating: 0x78, count: OmacyArtSchema.maximumUTF8Bytes + 1).write(to: url)
        }
        try assertRejectedArtNodePreservesCache { url in
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(OmacyArtSchema.maximumUTF8Bytes + 1))
            try handle.close()
        }
        try assertRejectedArtNodePreservesCache { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        try assertRejectedArtNodePreservesCache { url in
            let target = url.deletingLastPathComponent().appendingPathComponent("symlink-target")
            try Data("VALID BUT INDIRECT".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        }
    }

    func testOversizeAndDeepSettingsPreserveLastGood() throws {
        let invalidSettings = [
            Data(repeating: 0x20, count: OmacySettingsCodec.maximumJSONBytes + 1),
            Data(("{\"unknown\":" + String(repeating: "[", count: 33)
                + "0" + String(repeating: "]", count: 33) + "}").utf8),
        ]
        for (index, invalid) in invalidSettings.enumerated() {
            let repository = makeRepository()
            try repository.save(settings: OmacySettings(background: "#123456"), art: "GOOD")
            try invalid.write(to: repository.paths.settingsURL)

            XCTAssertEqual(repository.load().settings.background, "#123456", "case \(index)")
        }
    }

    func testFontSizeAcceptsPracticalMaximumAndRejectsLargerOrExtremeValues() throws {
        let maximum = try json(["fontSize": OmacySettingsCodec.maximumFontSize])
        XCTAssertEqual(
            OmacySettingsCodec.decodeValidated(maximum)?.fontSize,
            OmacySettingsCodec.maximumFontSize
        )
        XCTAssertNil(OmacySettingsCodec.decodeValidated(try json([
            "fontSize": OmacySettingsCodec.maximumFontSize.nextUp
        ])))
        XCTAssertNil(OmacySettingsCodec.decodeValidated(try json([
            "fontSize": Double.greatestFiniteMagnitude
        ])))
    }

    func testMigrationPrefersDefaultsWhenBothLegacySourcesExist() throws {
        let repository = makeRepository()
        var defaultsReads = 0
        var fileReads = 0
        let defaults = OmacyLegacyConfiguration(
            settingsData: try json(["background": "#111111"]), art: "DEFAULTS")
        let files = OmacyLegacyConfiguration(
            settingsData: try json(["background": "#222222"]), art: "FILES")

        let result = try repository.migrateIfNeeded(
            defaults: { defaultsReads += 1; return defaults },
            files: { fileReads += 1; return files }
        )

        XCTAssertEqual(result, .migrated)
        XCTAssertEqual(defaultsReads, 1)
        XCTAssertEqual(fileReads, 0)
        XCTAssertEqual(repository.load().art, "DEFAULTS")
        XCTAssertEqual(repository.load().settings.background, "#111111")
    }

    func testMigrationFallsBackToLegacyFiles() throws {
        let repository = makeRepository()
        let files = OmacyLegacyConfiguration(
            settingsData: try json(["background": "#222222"]), art: "FILES")

        let result = try repository.migrateIfNeeded(defaults: { nil }, files: { files })

        XCTAssertEqual(result, .migrated)
        XCTAssertEqual(repository.load().art, "FILES")
    }

    func testMigrationFallsBackPerFieldWhenDefaultsAreInvalidOrEmpty() throws {
        let repository = makeRepository()
        let defaults = OmacyLegacyConfiguration(settingsData: Data("{".utf8), art: "")
        let files = OmacyLegacyConfiguration(
            settingsData: try json(["background": "#222222"]), art: "FILES")

        XCTAssertEqual(
            try repository.migrateIfNeeded(defaults: { defaults }, files: { files }),
            .migrated
        )
        XCTAssertEqual(repository.load().settings.background, "#222222")
        XCTAssertEqual(repository.load().art, "FILES")
    }

    func testMigrationCombinesPartialDefaultsAndLegacyFilesPerField() throws {
        let repository = makeRepository()
        let defaults = OmacyLegacyConfiguration(
            settingsData: try json(["background": "#111111"]), art: nil)
        let files = OmacyLegacyConfiguration(
            settingsData: try json(["background": "#222222"]), art: "FILES ART")

        XCTAssertEqual(
            try repository.migrateIfNeeded(defaults: { defaults }, files: { files }),
            .migrated
        )
        XCTAssertEqual(repository.load().settings.background, "#111111")
        XCTAssertEqual(repository.load().art, "FILES ART")
    }

    func testMigrationNeverReadsLegacyWhenCanonicalConfigurationIsValid() throws {
        let repository = makeRepository()
        try repository.save(settings: OmacySettings(), art: "CANONICAL")
        var legacyWasRead = false

        let result = try repository.migrateIfNeeded(
            defaults: { legacyWasRead = true; return nil },
            files: { legacyWasRead = true; return nil }
        )

        XCTAssertEqual(result, .canonicalAlreadyValid)
        XCTAssertFalse(legacyWasRead)
    }

    func testMigrationRecordsAttemptBeforeDeniedLegacyAccessAndDoesNotRetry() throws {
        let repository = makeRepository()
        var attempts = 0

        XCTAssertThrowsError(try repository.migrateIfNeeded(
            defaults: { attempts += 1; throw CocoaError(.fileReadNoPermission) },
            files: { nil }
        ))
        XCTAssertEqual(
            try repository.migrateIfNeeded(defaults: { attempts += 1; return nil }, files: { nil }),
            .alreadyAttempted
        )
        XCTAssertEqual(attempts, 1)
    }

    func testExplicitMigrationRetryClearsMarker() throws {
        let repository = makeRepository()
        _ = try repository.migrateIfNeeded(defaults: { nil }, files: { nil })
        repository.retryMigration()

        let result = try repository.migrateIfNeeded(
            defaults: { OmacyLegacyConfiguration(settingsData: nil, art: "RETRIED") },
            files: { nil }
        )

        XCTAssertEqual(result, .migrated)
        XCTAssertEqual(repository.load().art, "RETRIED")
    }

    func testMigrationPreservesValidCanonicalHalfAndFillsInvalidHalf() throws {
        let repository = makeRepository()
        try FileManager.default.createDirectory(at: repository.paths.configDirectory, withIntermediateDirectories: true)
        try Data("CANONICAL ART".utf8).write(to: repository.paths.artURL)
        try Data("{".utf8).write(to: repository.paths.settingsURL)
        let legacy = OmacyLegacyConfiguration(
            settingsData: try json(["background": "#999999"]), art: "LEGACY ART")

        _ = try repository.migrateIfNeeded(defaults: { legacy }, files: { nil })

        XCTAssertEqual(repository.load().art, "CANONICAL ART")
        XCTAssertEqual(repository.load().settings.background, "#999999")
    }

    private func makeRepository(
        atomicWrite: ((Data, URL) throws -> Void)? = nil
    ) -> OmacyConfigRepository {
        let paths = OmacyConfigPaths(
            configDirectory: temporaryDirectory.appendingPathComponent("public", isDirectory: true),
            cacheDirectory: temporaryDirectory.appendingPathComponent("private", isDirectory: true),
            migrationMarkerURL: temporaryDirectory.appendingPathComponent("migration-attempted")
        )
        return OmacyConfigRepository(
            paths: paths,
            bundledArt: { "BUNDLED" },
            atomicWrite: atomicWrite
        )
    }

    private func assertRejectedArtNodePreservesCache(
        createInvalidNode: (URL) throws -> Void
    ) throws {
        let directory = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = OmacyConfigPaths(
            configDirectory: directory.appendingPathComponent("public", isDirectory: true),
            cacheDirectory: directory.appendingPathComponent("private", isDirectory: true),
            migrationMarkerURL: directory.appendingPathComponent("migration-attempted")
        )
        let repository = OmacyConfigRepository(paths: paths, bundledArt: { "BUNDLED" })
        try repository.save(settings: OmacySettings(), art: "LAST GOOD")
        try FileManager.default.removeItem(at: paths.artURL)
        try createInvalidNode(paths.artURL)

        let coldSnapshot = OmacyConfigRepository(paths: paths, bundledArt: { "BUNDLED" }).load()
        XCTAssertEqual(coldSnapshot.art, "LAST GOOD")
        XCTAssertEqual(try String(contentsOf: paths.cachedArtURL, encoding: .utf8), "LAST GOOD")
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}
