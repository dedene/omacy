import XCTest
@testable import Omacy

final class OmacyProcessRunnerTests: XCTestCase {
    func testDrainsOutputLargerThanPipeBuffer() async throws {
        let runner = OmacyProcessRunner(defaultTimeout: 2)
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/awk"),
            arguments: ["BEGIN { for (i=0; i<20000; i++) print \"0123456789\" }"]
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertGreaterThan(result.output.utf8.count, 200_000)
    }

    func testReturnsNonzeroStatusAndCombinedOutput() async throws {
        let runner = OmacyProcessRunner(defaultTimeout: 2)
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf failure-output; exit 7"]
        )

        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.output, "failure-output")
    }

    func testTimeoutFailsPromptly() async {
        let runner = OmacyProcessRunner(defaultTimeout: 0.05)
        let started = ContinuousClock.now

        do {
            _ = try await runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/tail"),
                arguments: ["-f", "/dev/null"]
            )
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? OmacyProcessRunnerError, .timedOut)
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }

    func testCancellationKillsTermIgnoringChild() async throws {
        let runner = OmacyProcessRunner(defaultTimeout: 5)
        let pidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("omacy-runner-\(UUID().uuidString).pid")
        let task = Task {
            try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo $$ > '\(pidURL.path)'; trap '' TERM; while :; do :; done"]
            )
        }
        for _ in 0..<20 where !FileManager.default.fileExists(atPath: pidURL.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        task.cancel()
        await XCTAssertProcessRunnerThrows(try await task.value)
        XCTAssertEqual(kill(pid, 0), -1)
        try? FileManager.default.removeItem(at: pidURL)
    }
}

private func XCTAssertProcessRunnerThrows(
    _ expression: @autoclosure () async throws -> Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
