import Darwin
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

    /// A command killed by a signal did not exit with a code: the message says what happened.
    @Test func commandStoppedByASignalSaysSoInsteadOfAnExitCode() async {
        defer { temp.remove() }
        let shell = ShellCommand(runner: FakeProcessRunner { _ in ProcessResult(exitCode: 128 + SIGKILL, signal: SIGKILL, stderr: "half done\n") })

        await #expect(throws: SourceError.commandStopped(signal: SIGKILL, output: "half done")) {
            try await shell.run("work", timeoutSeconds: 30, environment: [:]) { _ in }
        }
        #expect(SourceError.commandStopped(signal: SIGKILL, output: "half done").localizedDescription == "Command was stopped by a signal (Killed: 9). half done")
    }

    // MARK: Folder step copies exactly

    private func folderThenCommand(_ path: String) -> StepsSource {
        StepsSource(
            sourceId: UUID(),
            steps: [.folder(temp.path(path).path, name: "Vault"), .command("true", timeoutSeconds: 30)],
            stagingRoot: temp.path("staging"),
            runner: FakeProcessRunner()
        )
    }

    @Test func folderStepKeepsNamesByteForByte() async throws {
        defer { temp.remove() }
        let composed = "Мой план".precomposedStringWithCanonicalMapping
        let vault = try temp.directory("vault").path
        let descriptor = open(vault + "/" + composed + ".md", O_CREAT | O_WRONLY, 0o644)
        #expect(descriptor >= 0)
        close(descriptor)

        let payload = try await folderThenCommand("vault").collect(at: date)

        let names = try FileManager.default.contentsOfDirectory(atPath: payload.root.path)
        #expect(names.map { Array($0.utf8) } == [Array("\(composed).md".utf8)])
    }

    @Test func folderStepKeepsPermissionsAndLinks() async throws {
        defer {
            Permissions.unlockTree(temp.url)
            temp.remove()
        }
        try temp.file("vault/keys/id_ed25519", "PRIVATE")
        chmod(temp.path("vault/keys").path, 0o700)
        try FileManager.default.createSymbolicLink(atPath: temp.path("vault/link").path, withDestinationPath: "keys/id_ed25519")

        let payload = try await folderThenCommand("vault").collect(at: date)

        let keys = try FileManager.default.attributesOfItem(atPath: payload.root.appendingPathComponent("keys").path)
        #expect((keys[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: payload.root.appendingPathComponent("link").path) == "keys/id_ed25519")
    }

    @Test func folderStepGivenALinkToAFileCopiesTheFile() async throws {
        defer { temp.remove() }
        let real = try temp.file("dotfiles/zshrc", "export PATH=/opt/homebrew/bin")
        try temp.directory("home")
        try FileManager.default.createSymbolicLink(at: temp.path("home/.zshrc"), withDestinationURL: real)

        let payload = try await folderThenCommand("home/.zshrc").collect(at: date)

        #expect(try String(contentsOf: payload.root.appendingPathComponent(".zshrc"), encoding: .utf8) == "export PATH=/opt/homebrew/bin")
        let attributes = try FileManager.default.attributesOfItem(atPath: payload.root.appendingPathComponent(".zshrc").path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
    }

    @Test func folderStepFailsOnAnUnreadableSubfolder() async throws {
        defer {
            Permissions.unlockTree(temp.url)
            temp.remove()
        }
        try temp.file("vault/private/diary.md", "secret")
        chmod(temp.path("vault/private").path, 0)
        let reason = SourceError.unreadable(temp.path("vault/private").path).localizedDescription

        await #expect(throws: SourceError.stepFailed(index: 0, count: 2, name: "Vault", reason: reason)) {
            try await folderThenCommand("vault").collect(at: date)
        }
    }
}
