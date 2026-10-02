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
}
