import XCTest
@testable import Omacy

@MainActor
final class PluginManagerTests: XCTestCase {
    private let embedded = "/Applications/Omacy.app/Contents/PlugIns/OmacyScreensaver.appex"

    func testRegistrationClassificationIsDeterministic() {
        let matches = [
            OmacyPluginRegistration(path: "/tmp/Z.appex", version: "2"),
            OmacyPluginRegistration(path: "/Applications/A.appex", version: "1"),
        ]

        XCTAssertEqual(
            OmacyRegistrationState.classify(matches, fileExists: { _ in true }),
            .conflictingRegistrations([
                OmacyPluginRegistration(path: "/Applications/A.appex", version: "1"),
                OmacyPluginRegistration(path: "/tmp/Z.appex", version: "2"),
            ])
        )
        XCTAssertEqual(
            OmacyRegistrationState.classify([], fileExists: { _ in true }),
            .notRegistered
        )
    }

    func testConflictingRegistrationIsNotClassifiedAsMissing() {
        let state = OmacyRegistrationState.conflictingRegistrations([
            OmacyPluginRegistration(path: "/Applications/Omacy.appex", version: "1"),
            OmacyPluginRegistration(path: "/tmp/Omacy.appex", version: "1"),
        ])

        XCTAssertFalse(state.isMissing)
        XCTAssertTrue(state.hasConflicts)
    }

    func testRegistrationIsInstalledOnlyAtCurrentEmbeddedPath() {
        let current = OmacyRegistrationState.registered(
            OmacyPluginRegistration(path: embedded, version: "0.1.3")
        )
        let stale = OmacyRegistrationState.registered(
            OmacyPluginRegistration(path: "/tmp/OmacyScreensaver.appex", version: "0.1.2")
        )

        XCTAssertTrue(current.isRegistered(at: embedded))
        XCTAssertFalse(stale.isRegistered(at: embedded))
        XCTAssertFalse(OmacyRegistrationState.notRegistered.isRegistered(at: embedded))
    }

    func testInstallCleanupRemovesOnlyNoncurrentRegistrations() throws {
        let current = OmacyPluginRegistration(path: embedded, version: "0.1.3")
        let stale = OmacyPluginRegistration(path: "/tmp/OmacyScreensaver.appex", version: "0.1.2")

        XCTAssertEqual(
            try OmacyRegistrationState.missingRegistrations([stale, current])
                .pathsToRemoveBeforeInstalling(at: embedded),
            [stale.path]
        )
        XCTAssertEqual(
            try OmacyRegistrationState.registered(stale)
                .pathsToRemoveBeforeInstalling(at: embedded),
            [stale.path]
        )
        XCTAssertEqual(
            try OmacyRegistrationState.registered(current)
                .pathsToRemoveBeforeInstalling(at: embedded),
            []
        )
    }

    func testInstallCleanupRejectsConflictingRegistrations() {
        let current = OmacyPluginRegistration(path: embedded, version: "0.1.3")
        let stale = OmacyPluginRegistration(path: "/tmp/OmacyScreensaver.appex", version: "0.1.2")

        XCTAssertThrowsError(
            try OmacyRegistrationState.conflictingRegistrations([current, stale])
                .pathsToRemoveBeforeInstalling(at: embedded)
        )
    }

    func testRepairUnregistersEveryPathThenRegistersAndVerifies() async throws {
        var events: [String] = []
        let current = OmacyPluginRegistration(path: embedded, version: "0.1.3")
        let stale = OmacyPluginRegistration(path: "/tmp/Omacy.appex", version: "0.1.2")
        let repair = RegistrationRepair(
            unregister: { events.append("unregister:\($0)") },
            registerEmbeddedExtension: { events.append("register") },
            refreshRegistration: { events.append("refresh"); return .registered(current) }
        )

        try await repair.repair(
            .conflictingRegistrations([stale, current]),
            embeddedPath: embedded
        )

        XCTAssertEqual(events, [
            "unregister:/tmp/Omacy.appex",
            "register",
            "refresh",
        ])
    }

    func testRepairStopsBeforeRegisterWhenUnregisterFails() async {
        var events: [String] = []
        let stale = OmacyPluginRegistration(path: "/tmp/Omacy.appex", version: nil)
        let repair = RegistrationRepair(
            unregister: { _ in events.append("unregister"); throw TestFailure.expected },
            registerEmbeddedExtension: { events.append("register") },
            refreshRegistration: { events.append("refresh"); return .notRegistered }
        )

        await XCTAssertPluginManagerThrows(
            try await repair.repair(
                .missingRegistrations([stale]),
                embeddedPath: embedded
            )
        )
        XCTAssertEqual(events, ["unregister"])
    }

    func testRepairPreservesCurrentRegistrationWhenStaleRemovalFails() async {
        var events: [String] = []
        let current = OmacyPluginRegistration(path: embedded, version: "0.1.3")
        let stale = OmacyPluginRegistration(path: "/tmp/Stale.appex", version: nil)
        let repair = RegistrationRepair(
            unregister: { path in
                events.append("unregister:\(path)")
                if path == stale.path { throw TestFailure.expected }
            },
            registerEmbeddedExtension: { events.append("register") },
            refreshRegistration: { events.append("refresh"); return .registered(current) }
        )

        await XCTAssertPluginManagerThrows(
            try await repair.repair(
                .conflictingRegistrations([current, stale]),
                embeddedPath: embedded
            )
        )
        XCTAssertEqual(events, ["unregister:/tmp/Stale.appex"])
    }

    func testRepairRegistrationFailureNeverRemovesCurrentPath() async {
        var removed: [String] = []
        let current = OmacyPluginRegistration(path: embedded, version: "0.1.3")
        let stale = OmacyPluginRegistration(path: "/tmp/Stale.appex", version: nil)
        let repair = RegistrationRepair(
            unregister: { removed.append($0) },
            registerEmbeddedExtension: { throw TestFailure.expected },
            refreshRegistration: { .registered(current) }
        )

        await XCTAssertPluginManagerThrows(
            try await repair.repair(
                .conflictingRegistrations([current, stale]),
                embeddedPath: embedded
            )
        )
        XCTAssertEqual(removed, [stale.path])
        XCTAssertFalse(removed.contains(embedded))
    }

    func testSynchronousOuterLoadingTokenStaysBusyAcrossNestedSuspendedRefresh() {
        let activity = LoadingActivityCounter()

        // The wrapper takes its token synchronously, before scheduling async work.
        activity.begin()
        XCTAssertTrue(activity.isActive)

        // A nested refresh takes and releases its own token while the wrapper waits.
        activity.begin()
        activity.end()
        XCTAssertTrue(activity.isActive)

        activity.end()
        XCTAssertFalse(activity.isActive)
    }

    func testPluginQueryAllowsEmptyNoMatchButThrowsForGenuineFailure() throws {
        XCTAssertEqual(
            try OmacyPluginQuery.parse(
                .init(status: 1, output: ""),
                bundleIdentifier: "be.zenjoy.omacy.screensaver"
            ),
            []
        )
        XCTAssertThrowsError(
            try OmacyPluginQuery.parse(
                .init(status: 1, output: "pluginkit: database unavailable"),
                bundleIdentifier: "be.zenjoy.omacy.screensaver"
            )
        )
        XCTAssertThrowsError(
            try OmacyPluginQuery.parse(
                .init(status: 9, output: ""),
                bundleIdentifier: "be.zenjoy.omacy.screensaver"
            )
        )
    }

    func testPluginQueryParsesMatchesAndUsesSharedAliases() throws {
        let output = "+ be.zenjoy.omacy.screensaver(0.1.3) \(embedded)"
        XCTAssertEqual(
            try OmacyPluginQuery.parse(
                .init(status: 0, output: output),
                bundleIdentifier: "be.zenjoy.omacy.screensaver"
            ),
            [OmacyPluginRegistration(path: embedded, version: "0.1.3")]
        )
        XCTAssertTrue(OmacyScreensaverIdentity.isOmacy("Omacy"))
        XCTAssertTrue(OmacyScreensaverIdentity.isOmacy("OmacyScreensaver"))
        XCTAssertTrue(OmacyScreensaverIdentity.isOmacy("be.zenjoy.omacy.screensaver"))
    }

    func testRegistrationClassificationDistinguishesMissingAndOneLivePath() {
        let match = OmacyPluginRegistration(path: embedded, version: "0.1.3")

        XCTAssertEqual(
            OmacyRegistrationState.classify([match], fileExists: { _ in false }),
            .missingRegistrations([match])
        )
        XCTAssertEqual(
            OmacyRegistrationState.classify([match], fileExists: { _ in true }),
            .registered(match)
        )
        let secondMissing = OmacyPluginRegistration(path: "/tmp/Missing.appex", version: "0.1.2")
        XCTAssertEqual(
            OmacyRegistrationState.classify([secondMissing, match], fileExists: { _ in false }),
            .missingRegistrations([match, secondMissing])
        )
    }

    func testCurrentDisplayClassificationUsesEveryDisplayAndCentralAliases() {
        XCTAssertEqual(OmacyCurrentDisplayStatus.classify([]), .inactive(displayCount: 0))
        XCTAssertEqual(
            OmacyCurrentDisplayStatus.classify(["Flurry", "Random"]),
            .inactive(displayCount: 2)
        )
        XCTAssertEqual(
            OmacyCurrentDisplayStatus.classify(["Omacy", "Flurry"]),
            .activeOnSome(activeCount: 1, displayCount: 2)
        )
        XCTAssertEqual(
            OmacyCurrentDisplayStatus.classify(["OmacyScreensaver", "be.zenjoy.omacy.screensaver"]),
            .activeOnAll(displayCount: 2)
        )
    }

    func testPreparationOrdersRepairActivationAndReverification() async throws {
        var events: [String] = []
        var registrationChecks = 0
        var displayChecks = 0
        let live = OmacyPluginRegistration(path: embedded, version: "0.1.3")
        let preparation = ScreenSaverPreparation(
            embeddedPath: embedded,
            refreshRegistration: {
                events.append("registration")
                registrationChecks += 1
                return registrationChecks == 1 ? .notRegistered : .registered(live)
            },
            unregisterRegistration: { events.append("unregister:\($0)") },
            registerEmbeddedExtension: { events.append("register") },
            inspectCurrentDisplays: {
                events.append("displays")
                displayChecks += 1
                return displayChecks == 1
                    ? .inactive(displayCount: 2)
                    : .activeOnAll(displayCount: 2)
            },
            activateOnAllDisplaysAndSpaces: { events.append("activate") }
        )

        try await preparation.prepare()

        XCTAssertEqual(events, ["registration", "register", "registration", "displays", "activate", "displays"])
    }

    func testPreparationDoesNothingAfterRegistrationFailure() async {
        var events: [String] = []
        let preparation = ScreenSaverPreparation(
            embeddedPath: embedded,
            refreshRegistration: { events.append("registration"); return .notRegistered },
            unregisterRegistration: { events.append("unregister:\($0)") },
            registerEmbeddedExtension: { events.append("register"); throw TestFailure.expected },
            inspectCurrentDisplays: { events.append("displays"); return .activeOnAll(displayCount: 1) },
            activateOnAllDisplaysAndSpaces: { events.append("activate") }
        )

        await XCTAssertPluginManagerThrows(try await preparation.prepare())
        XCTAssertEqual(events, ["registration", "register"])
    }

    func testPreparationBlocksConflictingRegistrations() async {
        var reachedDisplays = false
        let registrations = [
            OmacyPluginRegistration(path: "/Applications/Omacy.appex", version: "1"),
            OmacyPluginRegistration(path: "/tmp/Omacy.appex", version: "1"),
        ]
        let preparation = ScreenSaverPreparation(
            embeddedPath: embedded,
            refreshRegistration: { .conflictingRegistrations(registrations) },
            unregisterRegistration: { _ in XCTFail("must not repair conflicts") },
            registerEmbeddedExtension: { XCTFail("must not repair conflicts") },
            inspectCurrentDisplays: { reachedDisplays = true; return .inactive(displayCount: 1) },
            activateOnAllDisplaysAndSpaces: { XCTFail("must not activate") }
        )

        await XCTAssertPluginManagerThrows(try await preparation.prepare())
        XCTAssertFalse(reachedDisplays)
    }

    func testPreparationRepairsMissingRegistration() async throws {
        var registerCount = 0
        let missing = OmacyPluginRegistration(path: embedded, version: "0.1.3")
        var states: [OmacyRegistrationState] = [.missingRegistrations([missing]), .registered(missing)]
        let preparation = ScreenSaverPreparation(
            embeddedPath: embedded,
            refreshRegistration: { states.removeFirst() },
            unregisterRegistration: { _ in XCTFail("must preserve the current embedded path") },
            registerEmbeddedExtension: { registerCount += 1 },
            inspectCurrentDisplays: { .activeOnAll(displayCount: 1) },
            activateOnAllDisplaysAndSpaces: { XCTFail("already active") }
        )

        try await preparation.prepare()
        XCTAssertEqual(registerCount, 1)
    }

    func testPreparationRemovesMissingStaleRegistrationsBeforeRegisteringEmbedded() async throws {
        var events: [String] = []
        let stale = OmacyPluginRegistration(path: "/tmp/Missing.appex", version: "0.1.2")
        let current = OmacyPluginRegistration(path: embedded, version: "0.1.3")
        var states: [OmacyRegistrationState] = [
            .missingRegistrations([stale]),
            .registered(current),
        ]
        let preparation = ScreenSaverPreparation(
            embeddedPath: embedded,
            refreshRegistration: { events.append("refresh"); return states.removeFirst() },
            unregisterRegistration: { events.append("unregister:\($0)") },
            registerEmbeddedExtension: { events.append("register") },
            inspectCurrentDisplays: { events.append("displays"); return .activeOnAll(displayCount: 1) },
            activateOnAllDisplaysAndSpaces: { XCTFail("already active") }
        )

        try await preparation.prepare()

        XCTAssertEqual(events, [
            "refresh",
            "unregister:/tmp/Missing.appex",
            "register",
            "refresh",
            "displays",
        ])
    }

    func testPreparationReplacesSingleLiveRegistrationAtStalePath() async throws {
        var events: [String] = []
        let stale = OmacyPluginRegistration(path: "/tmp/OldOmacy.appex", version: "0.1.2")
        let current = OmacyPluginRegistration(path: embedded, version: "0.1.3")
        var states: [OmacyRegistrationState] = [.registered(stale), .registered(current)]
        let preparation = ScreenSaverPreparation(
            embeddedPath: embedded,
            refreshRegistration: { events.append("refresh"); return states.removeFirst() },
            unregisterRegistration: { events.append("unregister:\($0)") },
            registerEmbeddedExtension: { events.append("register") },
            inspectCurrentDisplays: { events.append("displays"); return .activeOnAll(displayCount: 1) },
            activateOnAllDisplaysAndSpaces: { XCTFail("already active") }
        )

        try await preparation.prepare()

        XCTAssertEqual(events, [
            "refresh",
            "unregister:/tmp/OldOmacy.appex",
            "register",
            "refresh",
            "displays",
        ])
        XCTAssertFalse(events.contains("unregister:\(embedded)"))
    }

    func testPreparationRejectsFailedPostActivationVerification() async {
        var inspections = 0
        let live = OmacyPluginRegistration(path: embedded, version: "0.1.3")
        let preparation = ScreenSaverPreparation(
            embeddedPath: embedded,
            refreshRegistration: { .registered(live) },
            unregisterRegistration: { _ in XCTFail("already registered") },
            registerEmbeddedExtension: { XCTFail("already registered") },
            inspectCurrentDisplays: {
                inspections += 1
                return .activeOnSome(activeCount: 1, displayCount: 2)
            },
            activateOnAllDisplaysAndSpaces: {}
        )

        await XCTAssertPluginManagerThrows(try await preparation.prepare())
        XCTAssertEqual(inspections, 2)
    }

    func testPreparationStopsWhenActivationFails() async {
        var events: [String] = []
        let live = OmacyPluginRegistration(path: embedded, version: "0.1.3")
        let preparation = ScreenSaverPreparation(
            embeddedPath: embedded,
            refreshRegistration: { events.append("registration"); return .registered(live) },
            unregisterRegistration: { _ in XCTFail("already registered") },
            registerEmbeddedExtension: { XCTFail("already registered") },
            inspectCurrentDisplays: { events.append("displays"); return .inactive(displayCount: 1) },
            activateOnAllDisplaysAndSpaces: {
                events.append("activate")
                throw TestFailure.expected
            }
        )

        await XCTAssertPluginManagerThrows(try await preparation.prepare())
        XCTAssertEqual(events, ["registration", "displays", "activate"])
    }

    @MainActor
    func testLauncherPrefersBundleIdentifierResolution() async throws {
        let resolved = URL(fileURLWithPath: "/System/Resolved.app")
        var opened: URL?
        let launcher = ScreenSaverLauncher(
            resolveApplicationURL: { identifier in
                XCTAssertEqual(identifier, "com.apple.ScreenSaver.Engine")
                return resolved
            },
            canonicalApplicationURL: URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"),
            fileExists: { _ in true },
            openApplication: { opened = $0 }
        )

        try await launcher.launch()
        XCTAssertEqual(opened, resolved)
    }

    @MainActor
    func testLauncherUsesGuardedCanonicalFallbackAndPropagatesOpenErrors() async {
        let fallback = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        let launcher = ScreenSaverLauncher(
            resolveApplicationURL: { _ in nil },
            canonicalApplicationURL: fallback,
            fileExists: { $0 == fallback.path },
            openApplication: { _ in throw TestFailure.expected }
        )

        await XCTAssertPluginManagerThrows(try await launcher.launch()) { error in
            XCTAssertEqual(error as? TestFailure, .expected)
        }
    }

    @MainActor
    func testLauncherFailsWhenScreenSaverEngineCannotBeResolved() async {
        var didOpen = false
        let launcher = ScreenSaverLauncher(
            resolveApplicationURL: { _ in nil },
            canonicalApplicationURL: URL(fileURLWithPath: "/missing/ScreenSaverEngine.app"),
            fileExists: { _ in false },
            openApplication: { _ in didOpen = true }
        )

        await XCTAssertPluginManagerThrows(try await launcher.launch())
        XCTAssertFalse(didOpen)
    }
}

private enum TestFailure: Error, Equatable { case expected }

private func XCTAssertPluginManagerThrows(
    _ expression: @autoclosure () async throws -> Void,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
