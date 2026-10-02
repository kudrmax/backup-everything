import Foundation
import Testing
@testable import BackupCore

/// Reproductions of bugs found while reviewing how backups are run and scheduled. Each test fails until its bug is fixed.
struct FoundBugsOrchestrationTests {
    private let temp: TempDirectory
    private let time: FakeTimeSource
    private let store: Store
    private let inbox: ManualExportInbox
    private let coordinator: BackupCoordinator
    private let cloud: Destination
    private let disk: Destination
    private let start = Fixtures.date("2026-09-28 10:00:00")
    private let created = Fixtures.date("2026-09-27 00:00:00")

    init() throws {
        let temp = try TempDirectory()
        self.temp = temp
        time = FakeTimeSource(start)
        store = Store(dataDirectory: temp.path("data"))
        try temp.directory("cloud")
        try temp.directory("Downloads")
        try temp.directory("trash")
        try temp.file("vault/a.md", "alpha")
        cloud = Fixtures.localDestination("Cloud", at: temp.path("cloud"))
        disk = Fixtures.localDestination("HDD", at: temp.path("hdd"), expectedEvery: .days(30))

        let trash: ManualExportInbox.Trash = { url in
            try FileManager.default.moveItem(at: url, to: temp.path("trash/\(url.lastPathComponent)"))
        }
        let inbox = ManualExportInbox(pendingRoot: temp.path("work/pending"), naming: Fixtures.naming, trash: trash)
        self.inbox = inbox
        let runner = SystemProcessRunner()
        let chains = StepChainRunner(chainsRoot: temp.path("work/chains"), inbox: inbox, runner: runner, time: time, trash: trash)
        let stores = DefaultDestinationStoreFactory(runner: runner, rclone: RcloneLocator(candidates: []), naming: Fixtures.naming)
        let engine = BackupEngine(
            providers: DefaultSourceProviderFactory(runner: runner, stagingRoot: temp.path("work/staging"), inbox: inbox),
            stores: stores,
            retention: RetentionPolicy(timeZone: Fixtures.utc),
            naming: Fixtures.naming,
            time: time
        )
        coordinator = BackupCoordinator(
            store: store,
            engine: engine,
            inbox: inbox,
            chains: chains,
            stores: stores,
            time: time,
            calendar: Fixtures.calendar
        )
    }

    private func vault(_ destinations: [Destination]) -> Source {
        Fixtures.source(steps: [.folder(temp.path("vault").path, excludes: [])], destinations: destinations, createdAt: created)
    }

    private func move(_ from: String, to: String) throws {
        try FileManager.default.moveItem(at: temp.path(from), to: temp.path(to))
    }

    // MARK: Catch-up erases a failed scheduled run

    /// The vault can no longer be read, so the scheduled backup fails. A catch-up copy of yesterday's snapshot to a newly
    /// added disk must not make the source green and must not cancel the hourly retry of the failed backup.
    @Test func catchUpOfAnOldCopyDoesNotHideThatTheSourceItselfFails() async throws {
        defer { temp.remove() }
        var source = vault([cloud])
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        _ = try await coordinator.tick()

        time.advance(86_400)
        try move("vault", to: "vault-moved")
        let failed = try await coordinator.tick()
        #expect(failed.runs.first?.collectError != nil)
        #expect(try await coordinator.statusReport().overall == .error)
        let retryAt = time.now.addingTimeInterval(SchedulePlanner.retryInterval)
        #expect(try await coordinator.nextWake() == retryAt)

        time.advance(600)
        try temp.directory("second")
        let second = Fixtures.localDestination("Second", at: temp.path("second"))
        source.destinationIds.append(second.id)
        try store.saveConfig(Config(sources: [source], destinations: [cloud, second]))
        #expect(try await coordinator.tick().runs.map(\.trigger) == [.catchUp])

        #expect(try await coordinator.statusReport().overall == .error)
        let wake = try await coordinator.nextWake()
        #expect(wake != nil && wake! <= retryAt)
    }

    // MARK: Disabled source keeps nagging about a disk

    /// A disabled source is ignored by the status, and connecting the disk will never pay its debt: the app neither
    /// collects a disabled source nor has a copy of it. It must not keep asking to connect the disk every day.
    @Test func disabledSourceDoesNotKeepAskingToConnectTheDisk() async throws {
        defer { temp.remove() }
        var source = vault([disk])
        try store.saveConfig(Config(sources: [source], destinations: [disk]))
        _ = try await coordinator.tick()
        #expect(try store.loadState().debts.count == 1)

        source.enabled = false
        try store.saveConfig(Config(sources: [source], destinations: [disk]))

        time.advance(86_400 + 60)
        let result = try await coordinator.tick()
        #expect(!result.notices.contains { if case .connectDestination = $0 { true } else { false } })
        #expect(try await coordinator.statusReport().items.isEmpty)
    }

    // MARK: Unreadable folders are skipped silently

    /// A subfolder the app cannot read (permissions, macOS privacy protection) is silently left out of the copy,
    /// and the backup is reported as a success.
    @Test func unreadableSubfolderMakesTheBackupFailInsteadOfBeingSkipped() async throws {
        try temp.file("vault/private/secret.md", "secret")
        let locked = temp.path("vault/private")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            temp.remove()
        }
        try store.saveConfig(Config(sources: [vault([cloud])], destinations: [cloud]))

        let result = try await coordinator.tick()
        let copied = temp.exists("cloud/obsidian/2026-09-28_100000/private/secret.md")
        let reported = result.runs.first?.firstFailure != nil
        #expect(copied || reported, "secret.md is neither in the copy nor reported as a failure")
        let overall = try await coordinator.statusReport().overall
        #expect(copied || overall == .error)
    }

    // MARK: Interrupted command leaves its partial output in the copy

    /// The app quit while the command of step 2 was writing. After the restart the step is run again from its start,
    /// so the half-written file of the interrupted attempt must not end up in the copy.
    @Test func restartedCommandStepStartsFromACleanPlace() async throws {
        defer { temp.remove() }
        let source = Fixtures.source(
            name: "Database",
            steps: [
                .file("dump-request-*.txt", in: temp.path("Downloads").path, includeInCopy: false),
                .command("dump", timeoutSeconds: 60, name: "Dump"),
            ],
            schedule: .monthly,
            createdAt: created
        )
        let runner = StepChainRunner(
            chainsRoot: temp.path("work/chains"),
            inbox: inbox,
            runner: FakeProcessRunner { call in
                let output = URL(fileURLWithPath: call.environment["BACKUP_OUTPUT_DIR"]!)
                try Data("complete".utf8).write(to: output.appendingPathComponent("dump-2026-09-28_1005.sql"))
                return ProcessResult(exitCode: 0)
            },
            time: time,
            trash: { _ in }
        )
        let interrupted = ChainState(
            stepIndex: 1,
            stepId: source.steps[1].id,
            startedAt: start,
            stepEnteredAt: start,
            startedBy: .schedule
        )
        try temp.file("work/chains/\(source.id.uuidString)/input/dump-request-1.txt", "please")
        try temp.file("work/chains/\(source.id.uuidString)/output/dump-2026-09-28_1000.sql", "half writ")

        time.advance(300)
        guard case let .moved(next) = await runner.advance(source, chain: interrupted, lastPickup: nil, permissions: ChainPermissions(mayStart: false, mayRetry: false)),
              let afterCommand = next,
              case let .completed(package) = await runner.advance(source, chain: afterCommand, lastPickup: nil, permissions: ChainPermissions(mayStart: false, mayRetry: false)) else {
            Issue.record("the chain did not finish")
            return
        }
        let delivered = try FileManager.default.contentsOfDirectory(atPath: package.directory.path).sorted()
        #expect(delivered == ["dump-2026-09-28_1005.sql"])
    }

    // MARK: Command output that is not UTF-8 is lost

    /// One byte that is not valid UTF-8 (a file name in another encoding, binary progress output) makes the whole
    /// stdout disappear, so the error of a failed command loses its explanation.
    @Test func commandOutputSurvivesBytesThatAreNotUTF8() async throws {
        let result = try await SystemProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", #"printf 'copying caf\351.txt\n'; echo 'fatal: repository not found'; exit 1"#],
            environment: [:],
            timeout: 20
        )
        #expect(result.exitCode == 1)
        #expect(result.stdout.contains("fatal: repository not found"))
    }
}
