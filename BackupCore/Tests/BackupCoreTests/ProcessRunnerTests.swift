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
        #expect(Date().timeIntervalSince(started) < 3)
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

    @Test func timeoutStopsChildProcessesToo() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let result = try await runner.run(
            executable: shell,
            arguments: ["-c", "sleep 30 & echo $! > \"$PID_FILE\"; wait; echo done"],
            environment: ["PID_FILE": pidFile.path],
            timeout: 0.5
        )
        #expect(result.timedOut)
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let child = try #require(Int32(text))
        var alive = true
        for _ in 0..<30 where alive {
            alive = kill(child, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(!alive)
    }
}
