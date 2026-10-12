import BackupCore
import Foundation
import Testing
@testable import BackupEverything

@MainActor
struct AppModelQueryTests {
    private func chainState(at index: Int, by start: RunStart?, failure: String? = nil) -> AppState {
        var state = AppState()
        state.updateSource(exportId) {
            $0.lastRun = Date()
            $0.chain = ChainState(stepIndex: index, startedAt: Date(), stepEnteredAt: Date(), failure: failure, startedBy: start)
        }
        return state
    }

    private let exportId = UUID()

    private func exportSource(_ fixture: ModelFixture, schedule: Schedule = .monthly) -> Source {
        var source = fixture.source("Google", steps: [.file("takeout-*.zip", in: "/tmp"), .command("unpack", timeoutSeconds: 60)], schedule: schedule)
        source.id = exportId
        return source
    }

    @Test(arguments: [
        (RunStart?.some(.button), 0, String?.none, true),
        (.some(.schedule), 0, nil, false),
        (nil, 0, nil, false),
        (.some(.button), 0, "takeout: no file", false),
        (.some(.button), 1, nil, false),
        (.some(.button), 2, nil, false),
    ])
    func onlyAWaitStartedByTheButtonCanBeCancelled(start: RunStart?, index: Int, failure: String?, expected: Bool) async throws {
        let fixture = try ModelFixture()
        let source = exportSource(fixture)
        try await fixture.use(Config(sources: [source]), state: chainState(at: index, by: start, failure: failure))
        #expect(fixture.model.isWaitingForPerson(source) == expected)
    }

    @Test func armedSourceWaitsUntilItsDueTimeComes() async throws {
        let fixture = try ModelFixture()
        let source = exportSource(fixture)
        var state = AppState()
        state.updateSource(source.id) {
            $0.lastRun = Date()
            $0.armedAt = Date()
        }
        try await fixture.use(Config(sources: [source]), state: state)
        #expect(fixture.model.isWaitingForPerson(source))

        state.updateSource(source.id) { $0.lastRun = Date().addingTimeInterval(-90 * 86_400) }
        try await fixture.use(Config(sources: [source]), state: state)
        #expect(!fixture.model.isWaitingForPerson(source))
    }

    @Test func manualSourceArmedByTheButtonWaitsWithoutADueTime() async throws {
        let fixture = try ModelFixture()
        let source = exportSource(fixture, schedule: .manual)
        var state = AppState()
        state.updateSource(source.id) { $0.armedAt = Date() }
        try await fixture.use(Config(sources: [source]), state: state)
        #expect(fixture.model.nextDue(of: source) == nil)
        #expect(fixture.model.isWaitingForPerson(source))
    }

    @Test func notArmedSourceIsNotWaiting() async throws {
        let fixture = try ModelFixture()
        let source = exportSource(fixture)
        try await fixture.use(Config(sources: [source]), state: .backedUp(source))
        #expect(!fixture.model.isWaitingForPerson(source))
    }

    @Test func retryIsNotDueBeforeItsTime() async throws {
        let fixture = try ModelFixture()
        let disk = try fixture.disk()
        let notes = fixture.source("Notes", steps: [.folder("~/Notes")], to: [disk])
        let retry = Date.wholeSeconds(3_600)
        var state = AppState()
        state.updateSource(notes.id) { $0.retryAfter = retry }
        try await fixture.use(Config(sources: [notes], destinations: [disk]), state: state)
        #expect(fixture.model.nextDue(of: notes) == retry)
    }

    @Test func runThatDeliveredNothingIsNotALastBackup() async throws {
        let fixture = try ModelFixture()
        let disk = try fixture.disk(connected: false)
        let notes = fixture.source("Notes", steps: [.folder("~/Notes")], to: [disk])
        var state = AppState()
        state.updateSource(notes.id) { $0.lastRun = Date.wholeSeconds(-3600) }
        try await fixture.use(Config(sources: [notes], destinations: [disk]), state: state)
        #expect(fixture.model.lastBackup(of: notes) == nil)
        #expect(fixture.model.latestBackup == nil)
        #expect(fixture.model.lastSize(of: notes) == nil)
        #expect(fixture.model.lastDelivery(of: notes, to: disk) == nil)
    }

    /// The age is that of the newest copy still known to be on a destination of the source, not of the last run.
    @Test func lastBackupIsTheNewestDeliveredCopy() async throws {
        let fixture = try ModelFixture()
        let ssd = try fixture.disk("SSD", connected: false)
        let hdd = try fixture.disk("HDD", connected: false)
        let notes = fixture.source("Notes", steps: [.folder("~/Notes")], to: [ssd, hdd])
        let delivered = Date.wholeSeconds(-7200)
        var state = AppState()
        state.updateSource(notes.id) {
            $0.lastSuccess = Date.wholeSeconds(-3600)
            $0.lastRun = Date.wholeSeconds(-60)
        }
        state.recordCopy(sourceId: notes.id, destinationId: ssd.id, at: delivered.addingTimeInterval(-86_400))
        state.recordCopy(sourceId: notes.id, destinationId: hdd.id, at: delivered)
        try await fixture.use(Config(sources: [notes], destinations: [ssd, hdd]), state: state)
        #expect(fixture.model.lastBackup(of: notes) == delivered)
        #expect(fixture.model.latestBackup == delivered)
    }

    @Test func connectDeadlineCountsFromTheNewestCopyOnTheDisk() async throws {
        let fixture = try ModelFixture()
        let hdd = try fixture.disk("HDD", connected: false, every: 30)
        let ssd = try fixture.disk("SSD")
        let notes = fixture.source("Notes", steps: [.folder("~/Notes")], to: [hdd, ssd])
        var state = AppState.backedUp(notes)
        let copied = Date.wholeSeconds(-86_400)
        state.recordCopies(sourceId: notes.id, destinationId: hdd.id, [Snapshot(name: SnapshotNaming().name(for: copied), date: copied)], seenAt: copied)
        try await fixture.use(Config(sources: [notes], destinations: [hdd, ssd]), state: state)
        let model = fixture.model

        #expect(model.connectDeadline(of: hdd) == Calendar.current.date(byAdding: .day, value: 30, to: copied))
        #expect(model.connectDeadline(of: ssd) == nil)
        #expect(model.chain(of: notes.id) == nil)
    }

    @Test func diskWithoutACopyOfASourceIsDueNowLikeTheReporterSays() async throws {
        let fixture = try ModelFixture()
        let hdd = try fixture.disk("HDD", connected: false, every: 30)
        let notes = fixture.source("Notes", steps: [.folder("~/Notes")], to: [hdd])
        let photos = fixture.source("Photos", steps: [.folder("~/Photos")], to: [hdd])
        var state = AppState()
        let copied = Date.wholeSeconds(-86_400)
        state.recordCopies(sourceId: notes.id, destinationId: hdd.id, [Snapshot(name: SnapshotNaming().name(for: copied), date: copied)], seenAt: copied)
        try await fixture.use(Config(sources: [notes, photos], destinations: [hdd]), state: state)

        let deadline = try #require(fixture.model.connectDeadline(of: hdd))
        #expect(deadline <= Date())
        #expect(fixture.model.report.items.contains(.connectDestination(destinationId: hdd.id)))
    }

    @Test func copiesBeyondTheRulesAreListedWithTheCommandOnceTheRuleShrinks() async throws {
        let fixture = try ModelFixture()
        let hdd = try fixture.disk("HDD")
        let notes = try fixture.folderSource("Notes", to: [hdd])
        let older = Date.wholeSeconds(-3 * 86_400)
        try fixture.copy(of: notes, on: hdd, at: older)
        try fixture.copy(of: notes, on: hdd, at: Date.wholeSeconds(-86_400))
        try await fixture.use(Config(sources: [notes], destinations: [hdd]))

        var shrunk = notes
        shrunk.retention = RetentionRules(daily: 1, weekly: 0, monthly: 0, yearly: 0)
        await fixture.model.save(shrunk)

        #expect(await eventually { fixture.model.excessCopies.count == 1 })
        let excess = try #require(fixture.model.excessCopies.first)
        #expect(excess.items.map(\.snapshot.name) == [SnapshotNaming().name(for: older)])
        let command = try #require(fixture.model.excessCommand(for: excess))
        #expect(command.hasPrefix("sudo chown -R '\(NSUserName())' "))
        #expect(command.contains("trash "))
        #expect(command.contains(excess.items[0].folder.path))
    }

    /// The coordinator lists the copies; the window measures them in the background.
    @Test func copiesBeyondTheRulesAreSizedByTheWindow() async throws {
        let fixture = try ModelFixture()
        let hdd = try fixture.disk("HDD")
        var notes = try fixture.folderSource("Notes", to: [hdd])
        notes.retention = RetentionRules(daily: 1, weekly: 0, monthly: 0, yearly: 0)
        let older = Date.wholeSeconds(-3 * 86_400)
        try fixture.copy(of: notes, on: hdd, at: older)
        try fixture.copy(of: notes, on: hdd, at: Date.wholeSeconds(-86_400))
        let folder = URL(fileURLWithPath: hdd.path).appendingPathComponent("notes").appendingPathComponent(SnapshotNaming().name(for: older))
        try Data(repeating: 7, count: 50_000).write(to: folder.appendingPathComponent("photo.jpg"))
        try await fixture.use(Config(sources: [notes], destinations: [hdd]))
        await fixture.model.save(notes)

        let expected = try DestinationUsage().bytes(under: folder)
        #expect(expected > 0)
        #expect(await eventually { fixture.model.excessCopies.first?.items.first?.bytes == expected })
    }

    @Test func unpluggedDiskIsNotASetupProblem() {
        let hdd = UUID()
        let found: [StorageSetup.Problem] = [
            .accountMissing,
            .destinationNotReady(id: hdd, .folderMissing),
            .destinationNotReady(id: hdd, .accountMissing),
            .destinationNotReady(id: hdd, .volumeIgnoresOwners),
            .destinationNotReady(id: hdd, .notOwnedByBackupAccount(owner: "max")),
        ]
        #expect(AppModel.relevantSetupProblems(found) == [
            .accountMissing, .destinationNotReady(id: hdd, .volumeIgnoresOwners), .destinationNotReady(id: hdd, .notOwnedByBackupAccount(owner: "max")),
        ])
    }

    @Test func disabledSourceDoesNotAskToConnectTheDisk() async throws {
        let fixture = try ModelFixture()
        let hdd = try fixture.disk("HDD", every: 30)
        var notes = fixture.source("Notes", steps: [.folder("~/Notes")], to: [hdd])
        notes.enabled = false
        try await fixture.use(Config(sources: [notes], destinations: [hdd]), state: .backedUp(notes))
        #expect(fixture.model.connectDeadline(of: hdd) == nil)
    }

    @Test func disconnectedDiskIsShownAsOffline() async throws {
        let fixture = try ModelFixture()
        let hdd = fixture.unpluggedDisk("HDD")
        let ssd = try fixture.disk("SSD")
        try await fixture.use(Config(destinations: [hdd, ssd]))
        let model = fixture.model
        #expect(await eventually { model.unavailableDestinations == [hdd.id] })
        #expect(model.condition(of: hdd) == .offline)
        #expect(model.condition(of: ssd) == .available)
        #expect(await !model.isAvailable(hdd))
        #expect(await model.usedBytes(hdd) == nil)
        #expect(await model.snapshots(of: fixture.source("Notes", steps: []), in: hdd).isEmpty)
        #expect(await model.copies(in: hdd) == nil)
    }

    @Test func diskIsMeasuredAndRememberedForWhenItIsDisconnected() async throws {
        let fixture = try ModelFixture()
        let disk = try fixture.disk()
        let notes = try fixture.folderSource(to: [disk])
        try await fixture.use(Config(sources: [notes], destinations: [disk]))
        await fixture.model.tick()

        let model = fixture.model
        #expect(await eventually { (model.destinationUsage[disk.id] ?? 0) > 0 })
        #expect(model.freeSpace.map { $0 > 0 } == true)

        let reopened = AppModel(
            dataDirectory: fixture.store.dataDirectory,
            workDirectory: fixture.workDirectory,
            defaults: fixture.defaults.defaults
        )
        #expect(reopened.destinationUsage == model.destinationUsage)
    }

    @Test func rememberedSizesIgnoreEntriesThatAreNotDisks() throws {
        let defaults = TestDefaults()
        let disk = UUID()
        defaults.defaults.set([disk.uuidString: Int64(42), "junk": Int64(7)], forKey: "destinationUsage")
        let temp = try TemporaryFolder()
        let model = AppModel(
            dataDirectory: temp.url.appendingPathComponent("data"),
            workDirectory: temp.url.appendingPathComponent("work"),
            defaults: defaults.defaults
        )
        #expect(model.destinationUsage == [disk: 42])
    }

    @Test func removedDiskIsForgotten() async throws {
        let fixture = try ModelFixture()
        let disk = try fixture.disk()
        try await fixture.use(Config(destinations: [disk]))
        #expect(await eventually { fixture.model.destinationUsage[disk.id] != nil })
        await fixture.model.delete(disk)
        await fixture.model.tick()
        #expect(await eventually { fixture.model.destinationUsage.isEmpty })
    }

    @Test func diskConnectedLaterIsMeasuredRightAway() async throws {
        let fixture = try ModelFixture()
        let disk = try fixture.disk("HDD", connected: false)
        try await fixture.use(Config(destinations: [disk]))
        let model = fixture.model
        #expect(await eventually { model.unavailableDestinations == [disk.id] })
        guard case let .localFolder(path) = disk.kind else { return }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)

        await model.refresh()

        #expect(await eventually { model.unavailableDestinations.isEmpty })
        #expect(await eventually { model.destinationUsage[disk.id] != nil })
    }

    @Test func packagesWaitingForADiskCountTowardsTheSpaceBackupsNeed() async throws {
        let fixture = try ModelFixture()
        let pocketBook = fixture.source("PocketBook", steps: [.device(""), .folder("/Volumes/PB")])
        let package = fixture.workDirectory.appendingPathComponent("pending/\(pocketBook.id.uuidString)/2026-10-01_10-00-00", isDirectory: true)
        try fixture.temp.file("book.epub", in: package, contents: String(repeating: "b", count: 10_000))
        try fixture.temp.file("ignored.txt", in: fixture.workDirectory.appendingPathComponent("pending"))
        try await fixture.use(Config(sources: [pocketBook]))

        let model = fixture.model
        #expect(await eventually { model.waitingPackages[pocketBook.id] != nil })
        #expect(model.waitingPackages.count == 1)
        #expect((model.waitingPackages[pocketBook.id] ?? 0) >= 10_000)
    }

    @Test func spaceBackupsNeedComesFromTheLastGoodRunOfEachSource() async throws {
        let gate = Gate()
        await gate.open()
        let fixture = try ModelFixture(runner: GatedCommandRunner(gate: gate))
        let disk = try fixture.disk()
        let github = fixture.source("GitHub", steps: [.command("gh repo list", timeoutSeconds: 60)], to: [disk], schedule: .manual)
        try await fixture.use(Config(sources: [github], destinations: [disk]))
        await fixture.model.runNow(github)
        await fixture.model.runNow(github)

        let need = fixture.model.workingSpace
        #expect(need.largest == github)
        #expect(need.bytes == fixture.model.lastSize(of: github))
    }

    @Test func folderIsOpenedAndFileIsShownInFinder() throws {
        let fixture = try ModelFixture()
        let folder = try fixture.temp.folder("copy")
        let file = try fixture.temp.file("export.zip")
        fixture.model.reveal(folder)
        fixture.model.reveal(file)
        #expect(fixture.finder.opened == [folder])
        #expect(fixture.finder.selected == [file])
        #expect(fixture.model.problem == nil)
    }

    @Test func missingPlaceIsExplainedInsteadOfOpened() throws {
        let fixture = try ModelFixture()
        let missing = fixture.temp.url.appendingPathComponent("disks/HDD")
        fixture.model.reveal(missing)
        #expect(fixture.finder.opened.isEmpty)
        #expect(fixture.model.problem == "Not found: \(missing.path). The disk may not be connected.")
    }
}

extension Date {
    /// Settings files keep whole seconds, so a date read back compares equal only without the fraction.
    static func wholeSeconds(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + offset).rounded(.down))
    }
}
