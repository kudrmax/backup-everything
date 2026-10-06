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
        #expect(Date().timeIntervalSince(started) < 15, "stopped long before the 30 seconds, with room for a busy machine")
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

    @Test func reportsTheLatestOutputLineWhileTheProcessRuns() async throws {
        let lines = LockedBox<[String]>([])
        let result = try await runner.run(
            executable: shell,
            arguments: ["-c", "echo '1 of 2'; sleep 1; echo; echo '2 of 2'; sleep 1; echo err >&2"],
            environment: [:],
            timeout: nil,
            onOutput: { line in lines.set(lines.get() + [line]) }
        )
        #expect(result.exitCode == 0)
        #expect(lines.get() == ["1 of 2", "2 of 2"])
    }

    @Test func givenVariablesWinOverInheritedOnes() async throws {
        let result = try await runner.run(executable: shell, arguments: ["-c", "echo \"$HOME\""], environment: ["HOME": "/custom home"], timeout: nil)
        #expect(result.stdout == "/custom home\n")
    }

    @Test func commandThatIgnoresStopIsKilledAfterTheGracePeriod() async throws {
        let started = Date()
        let result = try await runner.run(
            executable: shell,
            arguments: ["-c", "trap '' TERM; while :; do sleep 0.1; done"],
            environment: [:],
            timeout: 0.3
        )
        #expect(result.timedOut)
        #expect(result.signal == SIGKILL)
        #expect(Date().timeIntervalSince(started) < 15)
    }

    /// One byte that is not valid UTF-8 (a file name in another encoding, binary progress output) must not make
    /// the whole stdout disappear, or the error of a failed command loses its explanation.
    @Test func commandOutputSurvivesBytesThatAreNotUTF8() async throws {
        let result = try await runner.run(
            executable: shell,
            arguments: ["-c", #"printf 'copying caf\351.txt\n'; echo 'fatal: repository not found'; printf '\377' >&2; exit 1"#],
            environment: [:],
            timeout: 20
        )
        #expect(result.exitCode == 1)
        #expect(result.stdout.contains("fatal: repository not found"))
        #expect(result.stderr == "\u{FFFD}")
    }

    private func startInBackground(_ runner: SystemProcessRunner) async throws -> (task: Task<ProcessResult, Error>, child: pid_t) {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("pid-\(UUID().uuidString)")
        let task = Task { [shell] in
            try await runner.run(
                executable: shell,
                arguments: ["-c", "sleep 30 & echo $! > \"$PID_FILE\"; wait"],
                environment: ["PID_FILE": pidFile.path],
                timeout: nil
            )
        }
        var text = ""
        while text.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
            text = ((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try? FileManager.default.removeItem(at: pidFile)
        return (task, try #require(Int32(text)))
    }

    private func isGone(_ pid: pid_t) async throws -> Bool {
        for _ in 0..<30 {
            if kill(pid, 0) != 0 { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test func cancellingTheTaskStopsTheCommandWithItsChildren() async throws {
        let groups = ProcessGroups()
        let (task, child) = try await startInBackground(SystemProcessRunner(groups: groups))
        #expect(groups.count == 1)

        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await isGone(child))
        #expect(groups.count == 0)
    }

    @Test func cancelledTaskDoesNotStartTheCommand() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("started-\(UUID().uuidString)")
        let task = Task { [runner, shell] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(executable: shell, arguments: ["-c", "touch \"\(marker.path)\""], environment: [:], timeout: nil)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// Quitting the app stops the commands it runs instead of leaving them to write into folders nobody watches.
    @Test func quittingStopsRunningCommandsWithTheirChildren() async throws {
        let groups = ProcessGroups()
        let (task, child) = try await startInBackground(SystemProcessRunner(groups: groups))

        groups.terminateAll(grace: 2)

        #expect(groups.isQuitting)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await isGone(child))
    }

    /// `kill` and logging out end a process at once, without `atexit`: the app handles the signal as Quit and ends itself.
    @Test func signalToQuitStopsRunningCommandsBeforeTheAppEnds() async throws {
        let groups = ProcessGroups()
        let exitCode = LockedBox<Int32?>(nil)
        groups.installTerminationHandlers(signals: [SIGUSR2]) { exitCode.set($0) }
        let (task, child) = try await startInBackground(SystemProcessRunner(groups: groups))

        kill(getpid(), SIGUSR2)

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await isGone(child))
        for _ in 0..<50 where exitCode.get() == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(exitCode.get() == 0)
        #expect(groups.isQuitting)
        #expect(ProcessGroups.terminationSignals == [SIGTERM, SIGHUP, SIGINT])
    }

    @Test func noCommandStartsOnceTheAppIsQuitting() async throws {
        let groups = ProcessGroups()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("started-\(UUID().uuidString)")
        groups.terminateAll(grace: 0)

        await #expect(throws: CancellationError.self) {
            try await SystemProcessRunner(groups: groups).run(executable: shell, arguments: ["-c", "touch \"\(marker.path)\""], environment: [:], timeout: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// A command spawned while the quit was being handled is not kept: the runner stops it right away.
    @Test func groupIsNotLetInOnceTheAppIsQuitting() {
        let groups = ProcessGroups()
        groups.terminateAll(grace: 0)

        #expect(!groups.insert(SpawnedGroup()))
        #expect(groups.count == 0)
    }

    @Test func signalThatStoppedTheCommandIsToldApartFromItsExitCode() async throws {
        let killed = try await runner.run(executable: shell, arguments: ["-c", "kill -KILL $$"], environment: [:], timeout: nil)
        #expect(killed.signal == SIGKILL)
        #expect(killed.exitCode == 128 + SIGKILL)

        let exited = try await runner.run(executable: shell, arguments: ["-c", "exit 9"], environment: [:], timeout: nil)
        #expect(exited.signal == nil)
        #expect(exited.exitCode == 9)
    }

    /// `kill(-pid)` with 0 or 1 would reach the app's own group or every process of the user.
    @Test func onlyARealGroupLeaderIsEverSignalled() {
        #expect(!ProcessIdentity.signalGroup(0, 0))
        #expect(!ProcessIdentity.signalGroup(1, 0))
        #expect(!ProcessIdentity.signalGroup(-getpid(), 0))
        #expect(ProcessIdentity.signalGroup(getpgrp(), 0))
    }

    @Test func quittingKillsACommandThatIgnoresTheRequestToStop() async throws {
        let groups = ProcessGroups()
        let started = FileManager.default.temporaryDirectory.appendingPathComponent("trap-\(UUID().uuidString)")
        let task = Task { [shell] in
            try await SystemProcessRunner(groups: groups).run(
                executable: shell,
                arguments: ["-c", "trap '' TERM; touch \"\(started.path)\"; while :; do sleep 0.1; done"],
                environment: [:],
                timeout: nil
            )
        }
        while !FileManager.default.fileExists(atPath: started.path) { try await Task.sleep(for: .milliseconds(20)) }
        try? FileManager.default.removeItem(at: started)

        groups.terminateAll(grace: 0.3)

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// Cancellation can come between the decision to start and the start itself: the command is stopped as soon as it appears.
    @Test func groupStoppedBeforeItsCommandStartedStopsItOnStart() async throws {
        let spawned = LockedBox<ProcessIdentity?>(nil)
        let task = Task { [shell] in
            try await SystemProcessRunner(groups: ProcessGroups()).run(
                executable: shell,
                arguments: ["-c", "sleep 30"],
                environment: [:],
                timeout: nil,
                onOutput: nil,
                onSpawn: { spawned.set($0) }
            )
        }
        while spawned.get() == nil { try await Task.sleep(for: .milliseconds(20)) }
        let group = SpawnedGroup()
        group.terminate()

        group.attach(try #require(spawned.get()).pid)

        #expect(try await task.value.signal == SIGTERM)
    }

    @Test func identityTellsAProcessFromALaterOneWithTheSamePid() throws {
        let current = try #require(ProcessIdentity.of(getpid()))
        #expect(current.isRunning)
        let reused = ProcessIdentity(pid: current.pid, startSeconds: current.startSeconds - 1, startMicroseconds: current.startMicroseconds)
        #expect(!reused.isRunning)
        reused.terminateGroup(grace: 0)
        #expect(ProcessIdentity.of(999_999) == nil)
    }

    @Test func groupLeftByAnEarlierLaunchIsKilledIfItIgnoresTheRequestToStop() async throws {
        let spawned = LockedBox<ProcessIdentity?>(nil)
        let task = Task { [shell] in
            try await SystemProcessRunner(groups: ProcessGroups()).run(
                executable: shell,
                arguments: ["-c", "trap '' TERM; while :; do sleep 0.1; done"],
                environment: [:],
                timeout: nil,
                onOutput: nil,
                onSpawn: { spawned.set($0) }
            )
        }
        while spawned.get() == nil { try await Task.sleep(for: .milliseconds(20)) }
        let orphan = try #require(spawned.get())
        try await Task.sleep(for: .milliseconds(200))

        orphan.terminateGroup(grace: 0.3)

        #expect(try await task.value.signal == SIGKILL)
    }

    @Test func latestLineIsFoundAfterLongOutput() async throws {
        let lines = LockedBox<[String]>([])
        _ = try await runner.run(
            executable: shell,
            arguments: ["-c", "head -c 20000 /dev/zero | tr '\\0' 'x'; echo; echo 'last step'"],
            environment: [:],
            timeout: 20,
            onOutput: { line in lines.set(lines.get() + [line]) }
        )
        #expect(lines.get().last == "last step")
    }
}
