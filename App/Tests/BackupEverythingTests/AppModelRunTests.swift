import BackupCore
import Foundation
import Testing
@testable import BackupEverything

@MainActor
struct AppModelRunTests {
    @Test func checkBacksUpWhatIsDueAndShowsTheResult() async throws {
        let fixture = try ModelFixture()
        let disk = try fixture.disk()
        let notes = try fixture.folderSource(to: [disk])
        try await fixture.use(Config(sources: [notes], destinations: [disk]))
        let changes = fixture.changes

        await fixture.model.tick()
        await fixture.settle()

        let model = fixture.model
        #expect(model.problem == nil)
        #expect(!model.isWorking)
        #expect(fixture.changes == changes + 1)
        #expect(model.runs.map(\.sourceName) == ["Notes"])
        #expect(model.lastBackup(of: notes) != nil)
        #expect(model.latestBackup == model.lastBackup(of: notes))
        #expect(model.lastSize(of: notes) == 2_000)
        #expect(model.lastDelivery(of: notes, to: disk)?.outcome == .delivered(pruned: 0, warning: nil))
        #expect(model.status(of: notes) == .ok)
        #expect(model.headline == "All good")
        #expect(model.headlineSymbol == StatusStyle.symbol(.ok))
        #expect(model.menuLines.isEmpty)
        #expect(model.stage(of: notes) == nil)
        #expect(model.usualDuration(of: notes) != nil)
        #expect(model.nextDue(of: notes).map { $0 > Date() } == true)
    }

    @Test func copyCanBeListedOpenedAndMeasured() async throws {
        let fixture = try ModelFixture()
        let disk = try fixture.disk()
        let notes = try fixture.folderSource(to: [disk])
        try await fixture.use(Config(sources: [notes], destinations: [disk]))
        await fixture.model.runNow(notes)

        let model = fixture.model
        let snapshots = await model.snapshots(of: notes, in: disk)
        let snapshot = try #require(snapshots.first)
        #expect(snapshots.count == 1)
        let url = try #require(model.localURL(of: snapshot, source: notes, in: disk))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("note.md").path))
        #expect(await model.isAvailable(disk))
        #expect(model.sources(backingUpTo: disk) == [notes])
        #expect(await model.copies(in: disk) == [notes.id: snapshots])
        #expect(await model.usedBytes(disk).map { $0 > 0 } == true)

        let previews = await model.retentionPreview(for: notes)
        #expect(previews.map(\.destination) == [disk])
        #expect(previews.first?.kept == [snapshot])
        #expect(previews.first?.doomed == [])
        #expect(previews.first?.id == disk.id)
    }

    @Test func cloudCopiesHaveNoFolderToOpen() throws {
        let fixture = try ModelFixture()
        let cloud = Destination(name: "Cloud", kind: .rclone(remote: "gdrive", path: "backups"))
        let source = fixture.source("Notes", steps: [.folder("~/Notes")], to: [cloud])
        let snapshot = Snapshot(name: "2026-10-02_10-00-00", date: Date())
        #expect(fixture.model.localURL(of: snapshot, source: source, in: cloud) == nil)
    }

    @Test func runningBackupIsShownWithItsProgress() async throws {
        let gate = Gate()
        let fixture = try ModelFixture(runner: GatedCommandRunner(gate: gate))
        let disk = try fixture.disk()
        let github = fixture.source("GitHub", steps: [.command("gh repo list", timeoutSeconds: 60)], to: [disk], schedule: .manual)
        try await fixture.use(Config(sources: [github], destinations: [disk]))
        let model = fixture.model

        let run = Task { await model.runNow(github) }
        #expect(await eventually { model.runStatus(of: github) == "3 of 5" })
        #expect(model.isWorking)
        #expect(model.stage(of: github) == .collecting)
        #expect(model.runningSource == github)
        #expect(model.currentSourceName == "GitHub")
        #expect(model.runStartedAt(of: github) != nil)
        #expect(model.runStep(of: github) == nil)
        #expect(model.headline == "Backing up")
        #expect(model.headlineSymbol == "arrow.triangle.2.circlepath.circle.fill")
        #expect(model.headlineColor == .blue)

        await gate.open()
        await run.value
        #expect(!model.isWorking)
        #expect(model.stage(of: github) == nil)
        #expect(model.runningSource == nil)
        #expect(model.lastDelivery(of: github, to: disk)?.outcome.isDelivered == true)
    }

    @Test func failedBackupIsNotifiedAndShownAsAnError() async throws {
        let gate = Gate()
        await gate.open()
        let fixture = try ModelFixture(runner: GatedCommandRunner(gate: gate, exitCode: 1))
        let disk = try fixture.disk()
        let github = fixture.source("GitHub", steps: [.command("gh repo list", timeoutSeconds: 60)], to: [disk], schedule: .manual)
        try await fixture.use(Config(sources: [github], destinations: [disk]))

        await fixture.model.runNow(github)
        await fixture.settle()

        let model = fixture.model
        #expect(fixture.notices.count == 1)
        guard case let .runFailed(sourceId, sourceName, _) = fixture.notices.first else {
            Issue.record("Expected a failure notice, got \(fixture.notices)")
            return
        }
        #expect(sourceId == github.id)
        #expect(sourceName == "GitHub")
        #expect(model.status(of: github).severity == .error)
        #expect(model.headline == "1 error")
        #expect(model.headlineColor == .red)
        #expect(model.menuLines.map(\.name) == ["GitHub"])
        #expect(model.usualDuration(of: github) == nil)
    }

    @Test func backingUpEverythingRunsEverySourceWithADestination() async throws {
        let fixture = try ModelFixture()
        let disk = try fixture.disk()
        let notes = try fixture.folderSource("Notes", to: [disk], schedule: .manual)
        let photos = try fixture.folderSource("Photos", to: [disk], schedule: .manual)
        let nowhere = try fixture.folderSource("Nowhere", to: [], schedule: .manual)
        try await fixture.use(Config(sources: [notes, photos, nowhere], destinations: [disk]))

        await fixture.model.runAll()

        #expect(Set(fixture.model.runs.map(\.sourceName)) == ["Notes", "Photos"])
        #expect(fixture.model.status(of: nowhere) == .noDestinations)
    }

    @Test func deviceRunSaysWhenTheDeviceCanBeUnplugged() async throws {
        let fixture = try ModelFixture()
        let disk = try fixture.disk()
        let books = try fixture.temp.folder("PocketBook/Books")
        try fixture.temp.file("book.epub", in: books)
        let pocketBook = fixture.source("PocketBook", steps: [.device(""), .folder(books.path)], to: [disk], schedule: .manual)
        try await fixture.use(Config(sources: [pocketBook], destinations: [disk]))

        await fixture.model.runNow(pocketBook)

        #expect(await eventually { fixture.notices.contains(.deviceCanBeUnplugged(sourceId: pocketBook.id, sourceName: "PocketBook")) })
        #expect(fixture.model.lastDelivery(of: pocketBook, to: disk)?.outcome.isDelivered == true)
    }

    @Test func exportStartedByTheButtonWaitsForThePersonUntilCancelled() async throws {
        let fixture = try ModelFixture()
        let disk = try fixture.disk()
        let downloads = try fixture.temp.folder("Downloads")
        let google = fixture.source("Google", steps: [.file("takeout-*.zip", in: downloads.path)], to: [disk], schedule: .monthly)
        try await fixture.use(Config(sources: [google], destinations: [disk]), state: .backedUp(google))
        let model = fixture.model

        await model.runNow(google)
        await fixture.settle()
        #expect(model.isWaitingForPerson(google))
        #expect(model.status(of: google) == .waiting)

        await model.cancelWaiting(google)
        #expect(!model.isWaitingForPerson(google))
    }

    @Test func foundFilesArePickedUpOnConfirmation() async throws {
        let fixture = try ModelFixture()
        let disk = try fixture.disk()
        let downloads = try fixture.temp.folder("Downloads")
        let export = try fixture.temp.file("takeout-1.zip", in: downloads)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: export.path)
        let google = fixture.source("Google", steps: [.file("takeout-*.zip", in: downloads.path, mode: .multiple)], to: [disk], schedule: .monthly)
        try await fixture.use(Config(sources: [google], destinations: [disk]))
        let model = fixture.model
        await model.tick()
        await fixture.settle()
        #expect(model.status(of: google) == .filesFound(count: 1, bytes: 7, downloading: false))
        #expect(model.menuLines.first?.canPickUp == true)

        await model.confirmPickup(google)
        await fixture.settle()

        #expect(model.lastDelivery(of: google, to: disk)?.outcome.isDelivered == true)
        #expect(model.status(of: google) == .ok)
    }

    @Test func startingOverForgetsWhereTheChainStopped() async throws {
        let fixture = try ModelFixture()
        let disk = try fixture.disk()
        let google = fixture.source("Google", steps: [.file("takeout-*.zip", in: "/tmp"), .command("unpack", timeoutSeconds: 60)], to: [disk])
        var state = AppState.backedUp(google)
        state.updateSource(google.id) {
            $0.chain = ChainState(stepIndex: 1, startedAt: Date(), stepEnteredAt: Date(), failure: "unpack: not found", startedBy: .button)
        }
        try await fixture.use(Config(sources: [google], destinations: [disk]), state: state)
        #expect(fixture.model.chain(of: google.id)?.stepIndex == 1)

        await fixture.model.restartChain(google)

        #expect(fixture.model.chain(of: google.id) == nil)
        #expect(fixture.model.isWaitingForPerson(google))
    }

    @Test func failureOfTheCheckItselfIsShownAndClearedByTheNextGoodOne() async throws {
        let fixture = try ModelFixture()
        let config = try Data(contentsOf: fixture.store.configURL)
        try Data("{ damaged".utf8).write(to: fixture.store.configURL)

        await fixture.model.tick()
        #expect(fixture.model.problem != nil)
        #expect(!fixture.model.isWorking)

        try config.write(to: fixture.store.configURL)
        await fixture.model.tick()
        #expect(fixture.model.problem == nil)
    }

    @Test func nextWakeComesFromTheSchedule() async throws {
        let fixture = try ModelFixture()
        let disk = try fixture.disk()
        let notes = try fixture.folderSource(to: [disk])
        try await fixture.use(Config(sources: [notes], destinations: [disk]))
        await fixture.model.tick()
        let wake = try #require(await fixture.model.nextWake())
        #expect(wake > Date())
    }

    @Test func rcloneRemotesAreListedWithoutTheTrailingColon() async throws {
        let runner = FakeProcessRunner(result: ProcessResult(exitCode: 0, stdout: "gdrive:\nwork:\nplain\n"))
        let fixture = try ModelFixture(runner: runner, rclone: RcloneLocator(candidates: ["/bin/sh"]))
        #expect(fixture.model.isRcloneInstalled)
        #expect(await fixture.model.rcloneRemotes() == ["gdrive", "work", "plain"])
    }

    @Test func rcloneErrorOrAbsenceGivesNoRemotes() async throws {
        let failing = try ModelFixture(runner: FakeProcessRunner(result: ProcessResult(exitCode: 1, stderr: "config broken")), rclone: RcloneLocator(candidates: ["/bin/sh"]))
        #expect(await failing.model.rcloneRemotes().isEmpty)
        let missing = try ModelFixture(rclone: RcloneLocator(candidates: []))
        #expect(!missing.model.isRcloneInstalled)
        #expect(await missing.model.rcloneRemotes().isEmpty)
    }
}

extension AppState {
    /// The source was backed up a moment ago, so nothing is due.
    static func backedUp(_ sources: Source...) -> AppState {
        var state = AppState()
        for source in sources {
            state.updateSource(source.id) {
                $0.lastRun = Date()
                $0.lastSuccess = Date()
            }
        }
        return state
    }
}
