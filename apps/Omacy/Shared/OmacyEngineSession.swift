import Foundation

struct OmacyEffectCatalog: Equatable {
    struct API {
        var count: () -> Int
        var get: (
            Int,
            UnsafeMutablePointer<UnsafePointer<UInt8>?>?,
            UnsafeMutablePointer<Int>?
        ) -> omacy_status

        static let live = API(
            count: omacy_effect_catalog_count,
            get: omacy_effect_catalog_get
        )
    }

    enum LoadError: Error, Equatable {
        case emptyCatalog
        case lookupFailed(index: Int, status: omacy_status)
        case invalidUTF8(index: Int)
        case emptyName(index: Int)
        case duplicateName(String)
    }

    let names: [String]

    init(names: [String]) {
        self.names = names
    }

    init(api: API = .live) throws {
        let count = api.count()
        guard count > 0 else { throw LoadError.emptyCatalog }
        var loaded: [String] = []
        loaded.reserveCapacity(count)
        var seen = Set<String>()
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var length = 0
            let status = api.get(index, &pointer, &length)
            guard status == OMACY_OK, let pointer else {
                throw LoadError.lookupFailed(index: index, status: status)
            }
            guard length > 0 else { throw LoadError.emptyName(index: index) }
            let bytes = UnsafeBufferPointer(start: pointer, count: length)
            guard let name = String(bytes: bytes, encoding: .utf8) else {
                throw LoadError.invalidUTF8(index: index)
            }
            guard seen.insert(name).inserted else { throw LoadError.duplicateName(name) }
            loaded.append(name)
        }
        names = loaded
    }

    static let live: OmacyEffectCatalog = {
        do { return try OmacyEffectCatalog() }
        catch { preconditionFailure("Invalid engine effect catalog: \(error)") }
    }()
}

struct OmacyEngineConfiguration: Equatable {
    let art: String
    let initialEffect: String
    let effects: [String]
    let background: (UInt8, UInt8, UInt8, UInt8)

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.art == rhs.art && lhs.initialEffect == rhs.initialEffect && lhs.effects == rhs.effects
            && lhs.background.0 == rhs.background.0 && lhs.background.1 == rhs.background.1
            && lhs.background.2 == rhs.background.2 && lhs.background.3 == rhs.background.3
    }
}

enum OmacyEngineFailure: Equatable {
    case recoverable(String)
    case programmingFault(String)
    case rejected(String)
}

enum OmacyEngineStep {
    case frame(OmacyStepResult)
    case failure(OmacyEngineFailure)
}

enum OmacyEngineTransition: Equatable {
    case committed(generation: UInt64)
    case ignoredUntilIdentityChanges
    case failed(OmacyEngineFailure)
}

enum OmacyEnginePreparation {
    case ready(OmacyEngineSession)
    case failed(OmacyEngineFailure)
}

/// The only boundary allowed to know about the engine's C pointers and status codes.
/// Keeping it MainActor-bound also makes the Rust thread-affinity contract explicit.
@MainActor
final class OmacyEngineSession {
    struct API {
        var create: (OmacyEngineConfiguration, UInt32, UInt32) -> (omacy_status, OpaquePointer?)
        var destroy: (OpaquePointer) -> Void
        var step: (OpaquePointer, Double) -> (omacy_status, OmacyStepResult)
        var beginNext: (OpaquePointer, OmacyEngineConfiguration, UInt32, UInt32) -> omacy_status
        var errorMessage: (OpaquePointer?) -> String
        var assertProgrammingFault: (String) -> Void

        static let live = API(
            create: { configuration, cols, rows in
                var output: OpaquePointer?
                let status = withOmacySessionConfig(configuration) { config in
                    omacy_session_create(config, cols, rows, &output)
                }
                return (status, output)
            },
            destroy: omacy_session_destroy,
            step: { pointer, elapsed in
                var result = OmacyStepResult()
                return (omacy_session_step(pointer, elapsed, &result), result)
            },
            beginNext: { pointer, configuration, cols, rows in
                let content = Array(configuration.art.utf8)
                let effectBytes = configuration.effects.map { Array($0.utf8) }
                return content.withUnsafeBufferPointer { contentBuffer in
                    withOmacyEffectSlices(effectBytes) { slices in
                        omacy_session_begin_next_with_config(
                            pointer,
                            contentBuffer.baseAddress,
                            content.count,
                            slices.baseAddress,
                            slices.count,
                            cols,
                            rows
                        )
                    }
                }
            },
            errorMessage: { pointer in
                var bytes = [CChar](repeating: 0, count: 512)
                guard omacy_session_error_message(pointer, &bytes, bytes.count) == OMACY_OK else {
                    return "no engine diagnostic"
                }
                return String(cString: bytes)
            },
            assertProgrammingFault: { message in assertionFailure(message) }
        )
    }

    private let api: API
    private var pointer: OpaquePointer?
    private(set) var configuration: OmacyEngineConfiguration
    private(set) var cols: UInt32
    private(set) var rows: UInt32
    private(set) var activeGeneration: UInt64 = 0
    private var rejectedIdentity: String?
    private var lastReportedIdentity: String?
    var report: (String) -> Void

    init?(
        configuration: OmacyEngineConfiguration,
        cols: UInt32,
        rows: UInt32,
        api: API = .live,
        report: @escaping (String) -> Void = { _ in }
    ) {
        self.api = api
        self.configuration = configuration
        self.cols = cols
        self.rows = rows
        self.report = report
        let (status, pointer) = api.create(configuration, cols, rows)
        guard status == OMACY_OK, let pointer else {
            report(Self.creationFailure(status, api: api).description)
            return nil
        }
        self.pointer = pointer
    }

    static func prepare(
        configuration: OmacyEngineConfiguration,
        cols: UInt32,
        rows: UInt32,
        api: API = .live,
        report: @escaping (String) -> Void = { _ in }
    ) -> OmacyEnginePreparation {
        let (status, pointer) = api.create(configuration, cols, rows)
        guard status == OMACY_OK, let pointer else {
            let failure = creationFailure(status, api: api)
            report(failure.description)
            return .failed(failure)
        }
        return .ready(OmacyEngineSession(
            adopting: pointer,
            configuration: configuration,
            cols: cols,
            rows: rows,
            api: api,
            report: report
        ))
    }

    deinit {
        guard let pointer else { return }
        api.destroy(pointer)
    }

    func step(elapsed: Double) -> OmacyEngineStep {
        guard let pointer else { return .failure(.programmingFault("session already stopped")) }
        let (status, result) = api.step(pointer, elapsed)
        return status == OMACY_OK ? .frame(result) : .failure(classify(status, pointer: pointer))
    }

    func beginNext(
        configuration: OmacyEngineConfiguration,
        cols: UInt32,
        rows: UInt32,
        fileIdentity: String
    ) -> OmacyEngineTransition {
        guard rejectedIdentity != fileIdentity else { return .ignoredUntilIdentityChanges }
        guard let pointer else { return .failed(.programmingFault("session already stopped")) }
        let status = api.beginNext(pointer, configuration, cols, rows)
        guard status == OMACY_OK else {
            let failure = classify(status, pointer: pointer)
            if case .rejected = failure {
                rejectedIdentity = fileIdentity
                if lastReportedIdentity != fileIdentity {
                    lastReportedIdentity = fileIdentity
                    report(failure.description)
                }
            }
            return .failed(failure)
        }
        if activeGeneration < .max { activeGeneration += 1 }
        rejectedIdentity = nil
        self.configuration = configuration
        self.cols = cols
        self.rows = rows
        return .committed(generation: activeGeneration)
    }

    func replacement(
        configuration: OmacyEngineConfiguration,
        cols: UInt32,
        rows: UInt32
    ) -> OmacyEnginePreparation {
        let (status, pointer) = api.create(configuration, cols, rows)
        guard status == OMACY_OK, let pointer else {
            return .failed(Self.creationFailure(status, api: api))
        }
        return .ready(OmacyEngineSession(
            adopting: pointer,
            configuration: configuration,
            cols: cols,
            rows: rows,
            api: api,
            report: report
        ))
    }

    private init(
        adopting pointer: OpaquePointer,
        configuration: OmacyEngineConfiguration,
        cols: UInt32,
        rows: UInt32,
        api: API,
        report: @escaping (String) -> Void
    ) {
        self.pointer = pointer
        self.configuration = configuration
        self.cols = cols
        self.rows = rows
        self.api = api
        self.report = report
    }

    private func classify(_ status: omacy_status, pointer: OpaquePointer) -> OmacyEngineFailure {
        let message = "\(Self.statusName(status)): \(api.errorMessage(pointer))"
        switch status {
        case OMACY_ERR_ENGINE, OMACY_ERR_DEAD, OMACY_ERR_PANIC:
            return .recoverable(message)
        case OMACY_OK, OMACY_ERR_NULL, OMACY_ERR_WRONG_THREAD:
            api.assertProgrammingFault(message)
            return .programmingFault(message)
        default:
            return .rejected(message)
        }
    }

    private static func statusName(_ status: omacy_status) -> String {
        guard let string = omacy_status_string(status) else { return "status \(status)" }
        return String(cString: string)
    }

    private static func creationFailure(_ status: omacy_status, api: API) -> OmacyEngineFailure {
        let message = "\(statusName(status)): \(api.errorMessage(nil))"
        switch status {
        case OMACY_ERR_ENGINE, OMACY_ERR_DEAD, OMACY_ERR_PANIC: return .recoverable(message)
        case OMACY_OK, OMACY_ERR_NULL, OMACY_ERR_WRONG_THREAD:
            api.assertProgrammingFault(message)
            return .programmingFault(message)
        default: return .rejected(message)
        }
    }
}

extension OmacyEngineFailure {
    var description: String {
        switch self {
        case .recoverable(let message), .programmingFault(let message), .rejected(let message): message
        }
    }
}

func withOmacySessionConfig<Result>(
    _ configuration: OmacyEngineConfiguration,
    _ body: (UnsafePointer<OmacySessionConfig>) -> Result
) -> Result {
    let art = Array(configuration.art.utf8)
    let effect = Array(configuration.initialEffect.utf8)
    let effectBytes = configuration.effects.map { Array($0.utf8) }
    return art.withUnsafeBufferPointer { artBuffer in
        effect.withUnsafeBufferPointer { effectBuffer in
            withOmacyEffectSlices(effectBytes) { slices in
                var config = OmacySessionConfig()
                config.ascii = artBuffer.baseAddress
                config.ascii_len = art.count
                config.effect = effectBuffer.baseAddress
                config.effect_len = effect.count
                config.effect_pool = slices.baseAddress
                config.effect_pool_count = slices.count
                config.bg_r = configuration.background.0
                config.bg_g = configuration.background.1
                config.bg_b = configuration.background.2
                config.bg_a = configuration.background.3
                return withUnsafePointer(to: &config, body)
            }
        }
    }
}

func withOmacyEffectSlices<Result>(
    _ bytes: [[UInt8]],
    _ body: (UnsafeBufferPointer<OmacyByteSlice>) -> Result
) -> Result {
    func descend(_ index: Int, _ slices: [OmacyByteSlice]) -> Result {
        guard index < bytes.count else { return slices.withUnsafeBufferPointer(body) }
        return bytes[index].withUnsafeBufferPointer { buffer in
            var next = slices
            next.append(OmacyByteSlice(ptr: buffer.baseAddress, len: buffer.count))
            return descend(index + 1, next)
        }
    }
    return descend(0, [])
}

@MainActor
final class OmacyDebouncer {
    private let delay: TimeInterval
    private var pending: DispatchWorkItem?

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func schedule(_ action: @escaping () -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem(block: action)
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
