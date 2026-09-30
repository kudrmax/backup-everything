import Foundation
import Testing
@testable import BackupCore

struct SourceProviderTests {
    private let temp: TempDirectory
    private let date = Fixtures.date("2026-09-28 14:30:00")

    init() throws {
        temp = try TempDirectory()
    }

    @Test func folderSourceReturnsFolderItself() async throws {
        defer { temp.remove() }
        try temp.file("vault/a.md")
        let payload = try await FolderSource(path: temp.path("vault").path, excludes: [".trash"]).collect(at: date)
        #expect(payload == Payload(root: temp.path("vault"), excludes: [".trash"], collectedAt: date))
    }

    @Test func folderSourceFailsWhenPathIsGone() async {
        defer { temp.remove() }
        let missing = temp.path("moved-vault").path
        await #expect(throws: SourceError.pathMissing(missing)) {
            try await FolderSource(path: missing, excludes: []).collect(at: date)
        }
    }

    @Test func commandSourceRunsShellAndCollectsOutputDirectory() async throws {
        defer { temp.remove() }
        let source = CommandSource(
            command: "echo hello > \"$BACKUP_OUTPUT_DIR/out.txt\"; test -d \"$BACKUP_SCRATCH_DIR\"; echo done",
            timeoutSeconds: 30,
            stagingRoot: temp.path("staging"),
            runner: SystemProcessRunner()
        )
        let payload = try await source.collect(at: date)
        #expect(try String(contentsOf: payload.root.appendingPathComponent("out.txt"), encoding: .utf8) == "hello\n")
        #expect(payload.details?.hasSuffix("done") == true)

        source.finish(payload, deliveredEverywhere: true)
        #expect(temp.names(in: "staging").isEmpty)
    }

    @Test func commandSourceReportsFailureWithOutputAndCleansUp() async {
        defer { temp.remove() }
        let runner = FakeProcessRunner { _ in ProcessResult(exitCode: 2, stdout: "step 1\n", stderr: "auth required\n") }
        let source = CommandSource(command: "gh repo list", timeoutSeconds: 30, stagingRoot: temp.path("staging"), runner: runner)
        await #expect(throws: SourceError.commandFailed(exitCode: 2, output: "step 1\nauth required")) {
            try await source.collect(at: date)
        }
        #expect(temp.names(in: "staging").isEmpty)
        #expect(runner.calls.first?.executable.path == "/bin/zsh")
        #expect(runner.calls.first?.arguments == ["-lc", "gh repo list"])
        #expect(runner.calls.first?.timeout == 30)
    }

    @Test func commandSourceReportsTimeout() async {
        defer { temp.remove() }
        let runner = FakeProcessRunner { _ in ProcessResult(exitCode: 15, timedOut: true) }
        let source = CommandSource(command: "sleep 100", timeoutSeconds: 5, stagingRoot: temp.path("staging"), runner: runner)
        await #expect(throws: SourceError.commandTimedOut(seconds: 5, output: "")) {
            try await source.collect(at: date)
        }
    }

    @Test func commandSourcePassesCommandOutputAsStatus() async throws {
        defer { temp.remove() }
        let runner = FakeProcessRunner(output: ["1 из 2 · first", "2 из 2 · second"])
        let source = CommandSource(command: "gh repo list", timeoutSeconds: 30, stagingRoot: temp.path("staging"), runner: runner)
        let statuses = LockedBox<[String]>([])
        let payload = try await source.collect(at: date) { status in statuses.set(statuses.get() + [status]) }
        source.finish(payload, deliveredEverywhere: true)
        #expect(statuses.get() == ["1 из 2 · first", "2 из 2 · second"])
    }
}
