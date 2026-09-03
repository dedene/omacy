import XCTest
@testable import Omacy

@MainActor
final class OmacyEngineSessionTests: XCTestCase {
    private let config = OmacyEngineConfiguration(
        art: "ART",
        initialEffect: "wipe",
        effects: ["wipe"],
        background: (0, 0, 0, 255)
    )

    func testOwnsPointerAndDestroysExactlyOnce() {
        var destroys = 0
        var session: OmacyEngineSession? = OmacyEngineSession(
            configuration: config,
            cols: 20,
            rows: 8,
            api: api(destroy: { _ in destroys += 1 })
        )
        XCTAssertNotNil(session)
        session = nil
        XCTAssertEqual(destroys, 1)
    }

    func testFailedReplacementKeepsOldSessionAlive() {
        var creates = 0
        var destroys = 0
        let fake = api(
            create: { _, _, _ in
                creates += 1
                return creates == 1 ? (OMACY_OK, OpaquePointer(bitPattern: 1)) : (OMACY_ERR_INVALID_ARG, nil)
            },
            destroy: { _ in destroys += 1 }
        )
        var session: OmacyEngineSession? = OmacyEngineSession(
            configuration: config, cols: 20, rows: 8, api: fake
        )

        let preparation = session!.replacement(configuration: config, cols: 30, rows: 10)
        guard case .failed(.rejected) = preparation else {
            return XCTFail("Expected typed construction rejection")
        }
        XCTAssertEqual(destroys, 0, "A failed preview preparation must not tear down the visible session")
        session = nil
        XCTAssertEqual(destroys, 1)
    }

    func testRejectedTransitionLeavesMirrorsAndRetriesOnlyForNewIdentity() {
        var calls = 0
        var reports = 0
        let fake = api(beginNext: { _, _, _, _ in
            calls += 1
            return OMACY_ERR_INVALID_ARG
        })
        let session = OmacyEngineSession(
            configuration: config, cols: 20, rows: 8, api: fake, report: { _ in reports += 1 }
        )!
        let next = OmacyEngineConfiguration(art: "NEXT", initialEffect: "beams", effects: ["beams"], background: (1, 2, 3, 255))

        guard case .failed(.rejected) = session.beginNext(
            configuration: next, cols: 30, rows: 10, fileIdentity: "one"
        ) else { return XCTFail("Expected rejection") }
        XCTAssertEqual(session.configuration.art, "ART")
        XCTAssertEqual(session.cols, 20)
        XCTAssertEqual(session.rows, 8)
        XCTAssertEqual(session.beginNext(configuration: next, cols: 30, rows: 10, fileIdentity: "one"),
                       .ignoredUntilIdentityChanges)
        _ = session.beginNext(configuration: next, cols: 30, rows: 10, fileIdentity: "two")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(reports, 2)
    }

    func testTransientEngineTransitionCanRetrySameIdentityAndThenCommit() {
        var calls = 0
        let fake = api(beginNext: { _, _, _, _ in
            calls += 1
            return calls == 1 ? OMACY_ERR_ENGINE : OMACY_OK
        })
        let session = OmacyEngineSession(configuration: config, cols: 20, rows: 8, api: fake)!
        let next = OmacyEngineConfiguration(
            art: "NEXT", initialEffect: "beams", effects: ["beams"], background: (0, 0, 0, 255)
        )

        guard case .failed(.recoverable) = session.beginNext(
            configuration: next, cols: 30, rows: 10, fileIdentity: "same"
        ) else { return XCTFail("Expected transient engine failure") }
        XCTAssertEqual(
            session.beginNext(configuration: next, cols: 30, rows: 10, fileIdentity: "same"),
            .committed(generation: 1)
        )
        XCTAssertEqual(calls, 2)
    }

    func testSuccessfulAtomicTransitionPromotesAllMirrorsAndGeneration() {
        let next = OmacyEngineConfiguration(art: "NEXT", initialEffect: "beams", effects: ["beams"], background: (1, 2, 3, 255))
        let session = OmacyEngineSession(configuration: config, cols: 20, rows: 8, api: api())!

        XCTAssertEqual(
            session.beginNext(configuration: next, cols: 30, rows: 10, fileIdentity: "two"),
            .committed(generation: 1)
        )
        XCTAssertEqual(session.activeGeneration, 1)
        XCTAssertEqual(session.configuration.art, "NEXT")
        XCTAssertEqual(session.cols, 30)
        XCTAssertEqual(session.rows, 10)
    }

    func testDeadStepIsRecoverable() {
        let fake = api(step: { _, _ in (OMACY_ERR_DEAD, OmacyStepResult()) })
        let session = OmacyEngineSession(configuration: config, cols: 20, rows: 8, api: fake)!
        guard case .failure(.recoverable) = session.step(elapsed: 1 / 60) else {
            return XCTFail("Dead sessions should be recreated by the renderer")
        }
    }

    func testCreationFailureReportsDetailedNullSessionDiagnostic() {
        var report = ""
        var fake = api(create: { _, _, _ in (OMACY_ERR_INVALID_ARG, nil) })
        fake.errorMessage = { pointer in
            XCTAssertNil(pointer)
            return "art contains a control character"
        }
        let session = OmacyEngineSession(
            configuration: config, cols: 20, rows: 8, api: fake, report: { report = $0 }
        )
        XCTAssertNil(session)
        XCTAssertTrue(report.contains("art contains a control character"))
    }

    func testTypedInitialCreationProgrammingFaultAssertsAndDoesNotProduceSession() {
        for status in [OMACY_OK, OMACY_ERR_NULL, OMACY_ERR_WRONG_THREAD] {
            var assertions = 0
            var fake = api(create: { _, _, _ in (status, nil) })
            fake.assertProgrammingFault = { _ in assertions += 1 }
            guard case .failed(.programmingFault) = OmacyEngineSession.prepare(
                configuration: config, cols: 20, rows: 8, api: fake
            ) else { return XCTFail("Expected typed programming fault for \(status)") }
            XCTAssertEqual(assertions, 1)
        }
    }

    func testTypedReplacementDistinguishesRecoverableAndProgrammingFailures() {
        var nextStatus = OMACY_OK
        var assertions = 0
        var fake = api(create: { _, _, _ in
            nextStatus == OMACY_OK
                ? (OMACY_OK, OpaquePointer(bitPattern: 1))
                : (nextStatus, nil)
        })
        fake.assertProgrammingFault = { _ in assertions += 1 }
        let session = OmacyEngineSession(configuration: config, cols: 20, rows: 8, api: fake)!

        nextStatus = OMACY_ERR_PANIC
        guard case .failed(.recoverable) = session.replacement(
            configuration: config, cols: 20, rows: 8
        ) else { return XCTFail("Expected recoverable replacement failure") }

        nextStatus = OMACY_ERR_ENGINE
        guard case .failed(.recoverable) = session.replacement(
            configuration: config, cols: 20, rows: 8
        ) else { return XCTFail("Expected transient engine replacement failure") }

        nextStatus = OMACY_ERR_WRONG_THREAD
        guard case .failed(.programmingFault) = session.replacement(
            configuration: config, cols: 20, rows: 8
        ) else { return XCTFail("Expected permanent programming failure") }
        XCTAssertEqual(assertions, 1)
    }

    func testPreviewDebouncerCoalescesRapidChanges() async {
        let fired = expectation(description: "latest preview")
        var values: [Int] = []
        let debouncer = OmacyDebouncer(delay: 0.01)
        debouncer.schedule { values.append(1) }
        debouncer.schedule { values.append(2) }
        debouncer.schedule {
            values.append(3)
            fired.fulfill()
        }
        await fulfillment(of: [fired], timeout: 1)
        XCTAssertEqual(values, [3])
    }

    func testEffectPoolBridgePreservesSliceCountBytesAndPointerLifetime() {
        let effects = [Array("wipe".utf8), Array("beams".utf8)]
        let result = withOmacyEffectSlices(effects) { slices -> [String] in
            XCTAssertEqual(slices.count, 2)
            return slices.map { slice in
                XCTAssertNotNil(slice.ptr)
                return String(decoding: UnsafeBufferPointer(start: slice.ptr, count: slice.len), as: UTF8.self)
            }
        }
        XCTAssertEqual(result, ["wipe", "beams"])

        withOmacyEffectSlices([]) { slices in
            XCTAssertEqual(slices.count, 0, "An empty pool is the ABI spelling for all effects")
        }
    }

    func testEffectCatalogLoadsEveryStaticUTF8NameInOrder() throws {
        let storage = ["beams", "wipe"].map { Array($0.utf8) }
        let catalog = try withCatalogStorage(storage) { api in
            try OmacyEffectCatalog(api: api)
        }

        XCTAssertEqual(catalog.names, ["beams", "wipe"])
    }

    func testLiveEffectCatalogMatchesEngineCountAndContainsOnlyUniqueNames() {
        let catalog = OmacyEffectCatalog.live
        XCTAssertEqual(catalog.names.count, omacy_effect_catalog_count())
        XCTAssertEqual(Set(catalog.names).count, catalog.names.count)
        XCTAssertTrue(catalog.names.contains("wipe"))
    }

    func testEffectCatalogRejectsInvalidUTF8AndOutOfRangeResults() {
        XCTAssertThrowsError(try withCatalogStorage([[0xFF]]) { api in
            try OmacyEffectCatalog(api: api)
        })

        let api = OmacyEffectCatalog.API(
            count: { 1 },
            get: { _, pointer, length in
                pointer?.pointee = nil
                length?.pointee = 0
                return OMACY_ERR_INVALID_ARG
            }
        )
        XCTAssertThrowsError(try OmacyEffectCatalog(api: api))
    }

    func testSelectedPoolIsPassedUnchangedToAtomicEngineBoundary() {
        var received: [String] = []
        let fake = api(beginNext: { _, configuration, _, _ in
            received = configuration.effects
            return OMACY_OK
        })
        let session = OmacyEngineSession(configuration: config, cols: 20, rows: 8, api: fake)!
        let next = OmacyEngineConfiguration(
            art: "NEXT", initialEffect: "random", effects: ["beams", "wipe"],
            background: (0, 0, 0, 255)
        )

        _ = session.beginNext(configuration: next, cols: 20, rows: 8, fileIdentity: "agent-write")

        XCTAssertEqual(received, ["beams", "wipe"])
    }

    func testRestrictedPoolIsPresentInInitialSessionConfig() {
        let initial = OmacyEngineConfiguration(
            art: "ART", initialEffect: "random", effects: ["beams", "wipe"],
            background: (1, 2, 3, 255)
        )

        let received = withOmacySessionConfig(initial) { pointer -> [String] in
            let config = pointer.pointee
            XCTAssertEqual(config.effect_pool_count, 2)
            return UnsafeBufferPointer(
                start: config.effect_pool,
                count: config.effect_pool_count
            ).map { slice in
                String(decoding: UnsafeBufferPointer(start: slice.ptr, count: slice.len), as: UTF8.self)
            }
        }

        XCTAssertEqual(received, ["beams", "wipe"])
    }

    func testSessionConfigBridgePreservesOptionalSeed() {
        let seeded = OmacyEngineConfiguration(
            art: "ART", initialEffect: "beams", effects: ["beams"],
            background: (1, 2, 3, 255), seed: 98_765
        )
        withOmacySessionConfig(seeded) { pointer in
            XCTAssertEqual(pointer.pointee.has_seed, 1)
            XCTAssertEqual(pointer.pointee.seed, 98_765)
        }

        let unseeded = OmacyEngineConfiguration(
            art: "ART", initialEffect: "beams", effects: ["beams"],
            background: (1, 2, 3, 255)
        )
        withOmacySessionConfig(unseeded) { pointer in
            XCTAssertEqual(pointer.pointee.has_seed, 0)
            XCTAssertEqual(pointer.pointee.seed, 0)
        }
    }

    private func withCatalogStorage<Result>(
        _ names: [[UInt8]],
        body: (OmacyEffectCatalog.API) throws -> Result
    ) rethrows -> Result {
        func descend(_ index: Int, _ pointers: [UnsafePointer<UInt8>?]) throws -> Result {
            guard index < names.count else {
                let api = OmacyEffectCatalog.API(
                    count: { names.count },
                    get: { catalogIndex, pointer, length in
                        guard names.indices.contains(catalogIndex) else {
                            pointer?.pointee = nil
                            length?.pointee = 0
                            return OMACY_ERR_INVALID_ARG
                        }
                        pointer?.pointee = pointers[catalogIndex]
                        length?.pointee = names[catalogIndex].count
                        return OMACY_OK
                    }
                )
                return try body(api)
            }
            return try names[index].withUnsafeBufferPointer { buffer in
                try descend(index + 1, pointers + [buffer.baseAddress])
            }
        }
        return try descend(0, [])
    }

    private func api(
        create: @escaping (OmacyEngineConfiguration, UInt32, UInt32) -> (omacy_status, OpaquePointer?) = {
            _, _, _ in (OMACY_OK, OpaquePointer(bitPattern: 1))
        },
        destroy: @escaping (OpaquePointer) -> Void = { _ in },
        step: @escaping (OpaquePointer, Double) -> (omacy_status, OmacyStepResult) = {
            _, _ in (OMACY_OK, OmacyStepResult())
        },
        beginNext: @escaping (OpaquePointer, OmacyEngineConfiguration, UInt32, UInt32) -> omacy_status = {
            _, _, _, _ in OMACY_OK
        }
    ) -> OmacyEngineSession.API {
        OmacyEngineSession.API(
            create: create,
            destroy: destroy,
            step: step,
            beginNext: beginNext,
            errorMessage: { _ in "fake diagnostic" },
            assertProgrammingFault: { _ in }
        )
    }
}
