import Foundation
import Darwin

struct OmacyPluginProcessResult: Equatable, Sendable {
    let status: Int32
    let output: String
}

enum OmacyProcessRunnerError: LocalizedError, Equatable {
    case timedOut

    var errorDescription: String? {
        switch self {
        case .timedOut: return "The process timed out."
        }
    }
}

enum OmacyPluginQuery {
    static func parse(
        _ result: OmacyPluginProcessResult,
        bundleIdentifier: String
    ) throws -> [OmacyPluginRegistration] {
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status == 1, trimmed.isEmpty { return [] }
        guard result.status == 0 else {
            throw PluginError.processFailed("/usr/bin/pluginkit", result.status, result.output)
        }
        return result.output.components(separatedBy: "\n").compactMap { line in
            guard line.contains(bundleIdentifier) else { return nil }
            var version: String?
            if let start = line.firstIndex(of: "("), let end = line.firstIndex(of: ")") {
                version = String(line[line.index(after: start)..<end])
            }
            let path = line.firstIndex(of: "/").map { String(line[$0...]) } ?? ""
            return OmacyPluginRegistration(path: path, version: version)
        }
    }
}

actor OmacyProcessRunner {
    private let defaultTimeout: TimeInterval

    init(defaultTimeout: TimeInterval = 10) {
        self.defaultTimeout = defaultTimeout
    }

    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) async throws -> OmacyPluginProcessResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        async let outputData = pipe.fileHandleForReading.readToEnd() ?? Data()

        do {
            let status = try await waitForExit(
                process,
                timeout: timeout ?? defaultTimeout
            )
            let data = try await outputData
            return OmacyPluginProcessResult(
                status: status,
                output: String(data: data, encoding: .utf8) ?? ""
            )
        } catch {
            await stopAndAwaitExit(process)
            _ = try? await outputData
            throw error
        }
    }

    private func waitForExit(
        _ process: Process,
        timeout: TimeInterval
    ) async throws -> Int32 {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while process.isRunning {
            try Task.checkCancellation()
            if ContinuousClock.now >= deadline { throw OmacyProcessRunnerError.timedOut }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return process.terminationStatus
    }

    private func stopAndAwaitExit(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        let graceDeadline = ContinuousClock.now.advanced(by: .milliseconds(100))
        while process.isRunning, ContinuousClock.now < graceDeadline {
            await uncancellableDelay(milliseconds: 10)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        while process.isRunning {
            await uncancellableDelay(milliseconds: 10)
        }
    }

    private func uncancellableDelay(milliseconds: Int) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(
                deadline: .now() + .milliseconds(milliseconds)
            ) { continuation.resume() }
        }
    }
}
