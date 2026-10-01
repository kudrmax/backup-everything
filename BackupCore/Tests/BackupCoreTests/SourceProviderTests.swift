import Foundation
import Testing
@testable import BackupCore

struct SourceProviderTests {
    private let temp: TempDirectory
    private let date = Fixtures.date("2026-09-28 14:30:00")

    init() throws {
        temp = try TempDirectory()
    }

    private func commandSource(_ command: String, timeoutSeconds: Int, runner: any ProcessRunner) -> StepsSource {
        StepsSource(sourceId: UUID(), steps: [.command(command, timeoutSeconds: timeoutSeconds)], stagingRoot: temp.path("staging"), runner: runner)
    }

    @Test func automaticStepsBuildOneCopyTogether() async throws {
        defer { temp.remove() }
        try temp.file("anki/collection.anki2", "db")
        try temp.file("anki/backups/old.colpkg", "old")
        let events = LockedBox<[RunProgress]>([])
        let sourceId = UUID()
        let source = StepsSource(
            sourceId: sourceId,
            steps: [
                .folder(temp.path("anki").path, excludes: ["backups"]),
                .command(#"echo notes > "$BACKUP_OUTPUT_DIR/notes.csv""#, timeoutSeconds: 30),
            ],
            stagingRoot: temp.path("staging"),
            runner: SystemProcessRunner(),
            progress: { event in events.set(events.get() + [event]) }
        )
        let payload = try await source.collect(at: date)
        #expect(try FileManager.default.contentsOfDirectory(atPath: payload.root.path).sorted() == ["collection.anki2", "notes.csv"])
        #expect(events.get() == [.step(sourceId: sourceId, index: 0, count: 2), .step(sourceId: sourceId, index: 1, count: 2)])
        source.finish(payload, deliveredEverywhere: true)
        #expect(temp.names(in: "staging").isEmpty)
    }

    @Test func failedStepOfSeveralNamesItself() async {
        defer { temp.remove() }
        let source = StepsSource(
            sourceId: UUID(),
            steps: [.folder(temp.path("gone").path, name: "Books"), .command("true", timeoutSeconds: 30)],
            stagingRoot: temp.path("staging"),
            runner: FakeProcessRunner()
        )
        await #expect(throws: SourceError.stepFailed(index: 0, count: 2, name: "Books", reason: SourceError.pathMissing(temp.path("gone").path).localizedDescription)) {
            try await source.collect(at: date)
        }
        #expect(temp.names(in: "staging").isEmpty)
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
        let source = commandSource("echo hello > \"$BACKUP_OUTPUT_DIR/out.txt\"; test -d \"$BACKUP_SCRATCH_DIR\"; test -d \"$BACKUP_INPUT_DIR\"; echo done", timeoutSeconds: 30, runner: SystemProcessRunner())
        let payload = try await source.collect(at: date)
        #expect(try String(contentsOf: payload.root.appendingPathComponent("out.txt"), encoding: .utf8) == "hello\n")
        #expect(payload.details?.hasSuffix("done") == true)

        source.finish(payload, deliveredEverywhere: true)
        #expect(temp.names(in: "staging").isEmpty)
    }

    @Test func commandSourceReportsFailureWithOutputAndCleansUp() async {
        defer { temp.remove() }
        let runner = FakeProcessRunner { _ in ProcessResult(exitCode: 2, stdout: "step 1\n", stderr: "auth required\n") }
        let source = commandSource("gh repo list", timeoutSeconds: 30, runner: runner)
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
        let source = commandSource("sleep 100", timeoutSeconds: 5, runner: runner)
        await #expect(throws: SourceError.commandTimedOut(seconds: 5, output: "")) {
            try await source.collect(at: date)
        }
    }

    @Test func commandSourcePassesCommandOutputAsStatus() async throws {
        defer { temp.remove() }
        let runner = FakeProcessRunner(output: ["1 of 2 · first", "2 of 2 · second"])
        let source = commandSource("gh repo list", timeoutSeconds: 30, runner: runner)
        let statuses = LockedBox<[String]>([])
        let payload = try await source.collect(at: date) { status in statuses.set(statuses.get() + [status]) }
        source.finish(payload, deliveredEverywhere: true)
        #expect(statuses.get() == ["1 of 2 · first", "2 of 2 · second"])
    }

    @Test func shellCommandPassesEnvironmentAndReportsFailures() async throws {
        defer { temp.remove() }
        let runner = FakeProcessRunner(output: ["1 of 2"]) { call in
            call.environment["MODE"] == "fail" ? ProcessResult(exitCode: 3, stdout: "out\n", stderr: "boom\n") : ProcessResult(exitCode: 0, stdout: "done\n")
        }
        let shell = ShellCommand(runner: runner)
        let lines = LockedBox<[String]>([])

        let tail = try await shell.run("echo hi", timeoutSeconds: 30, environment: ["MODE": "ok"]) { lines.set(lines.get() + [$0]) }
        #expect(tail == "done")
        #expect(lines.get() == ["1 of 2"])
        #expect(runner.calls.first?.arguments == ["-lc", "echo hi"])
        #expect(runner.calls.first?.executable.path == "/bin/zsh")
        #expect(runner.calls.first?.timeout == 30)

        await #expect(throws: SourceError.commandFailed(exitCode: 3, output: "out\nboom")) {
            try await shell.run("echo hi", timeoutSeconds: 30, environment: ["MODE": "fail"]) { _ in }
        }
    }
}
