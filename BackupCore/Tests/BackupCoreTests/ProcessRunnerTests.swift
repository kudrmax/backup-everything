import Foundation
import Testing
@testable import BackupCore

struct ProcessRunnerTests {
    private let runner = SystemProcessRunner()
    private let shell = URL(fileURLWithPath: "/bin/sh")

    @Test func capturesOutputAndExitCode() async throws {
        let result = try await runner.run(
            executable: shell,
            arguments: ["-c", "echo out; echo err >&2; exit 3"],
            environment: [:],
            timeout: nil
        )
        #expect(result == ProcessResult(exitCode: 3, stdout: "out\n", stderr: "err\n", timedOut: false))
    }

    @Test func passesEnvironmentOnTopOfInherited() async throws {
        let result = try await runner.run(
            executable: shell,
            arguments: ["-c", "echo \"$BACKUP_TEST_VALUE:${HOME:+home}\""],
            environment: ["BACKUP_TEST_VALUE": "42"],
            timeout: nil
        )
        #expect(result.stdout == "42:home\n")
    }

    @Test func stopsProcessOnTimeout() async throws {
        let started = Date()
        let result = try await runner.run(executable: shell, arguments: ["-c", "exec sleep 30"], environment: [:], timeout: 0.5)
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func handlesOutputLargerThanPipeBuffer() async throws {
        let result = try await runner.run(
            executable: shell,
            arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' 'a'"],
            environment: [:],
            timeout: 20
        )
        #expect(result.stdout.count == 300_000)
    }

    @Test func missingExecutableThrows() async {
        await #expect(throws: (any Error).self) {
            try await runner.run(executable: URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], environment: [:], timeout: nil)
        }
    }
}
