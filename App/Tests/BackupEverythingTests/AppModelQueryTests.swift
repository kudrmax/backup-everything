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

    @Test func lastBackupIsTheNewestDeliveredCopy() async throws {
        let fixture = try ModelFixture()
        let notes = fixture.source("Notes", steps: [.folder("~/Notes")])
        let delivered = Date.wholeSeconds(-7200)
        var state = AppState()
        state.updateSource(notes.id) {
            $0.lastSuccess = delivered
            $0.lastRun = Date.wholeSeconds(-60)
        }
        try await fixture.use(Config(sources: [notes]), state: state)
        #expect(fixture.model.lastBackup(of: notes) == delivered)
        #expect(fixture.model.latestBackup == delivered)
    }

    /// State written before the newest delivered copy was remembered has only the last run; the history tells which runs delivered.
    @Test func lastBackupOfOldSettingsComesFromDeliveredRunsInTheHistory() async throws {
        let fixture = try ModelFixture()
        let disk = try fixture.disk()
        let notes = fixture.source("Notes", steps: [.folder("~/Notes")], to: [disk])
        let collected = Date.wholeSeconds(-7200)
        let record = { (started: Date, collected: Date?, outcome: DeliveryOutcome) in
            RunRecord(
                sourceId: notes.id, sourceName: "Notes", trigger: .scheduled, startedAt: started, finishedAt: started,
                collectedAt: collected, deliveries: [Delivery(destinationId: disk.id, destinationName: "HDD", outcome: outcome)]
            )
        }
        try fixture.store.appendRun(record(Date.wholeSeconds(-9000), nil, .delivered(pruned: 0, warning: nil)))
        try fixture.store.appendRun(record(Date.wholeSeconds(-7300), collected, .delivered(pruned: 0, warning: nil)))
        try fixture.store.appendRun(record(Date.wholeSeconds(-60), Date.wholeSeconds(-60), .unavailable))
        var state = AppState()
        state.updateSource(notes.id) { $0.lastRun = Date.wholeSeconds(-60) }
        try await fixture.use(Config(sources: [notes], destinations: [disk]), state: state)
        #expect(fixture.model.lastBackup(of: notes) == collected)
    }

    @Test func missedCopiesAreTrackedPerDisk() async throws {
        let fixture = try ModelFixture()
        let hdd = try fixture.disk("HDD", connected: false, every: 30)
        let ssd = try fixture.disk("SSD")
        let cloud = try fixture.disk("Cloud")
        let notes = fixture.source("Notes", steps: [.folder("~/Notes")], to: [hdd, ssd, cloud])
        let photos = fixture.source("Photos", steps: [.folder("~/Photos")], to: [hdd])
        var state = AppState.backedUp(notes, photos)
        state.debts = [
            Debt(sourceId: notes.id, destinationId: hdd.id, since: Date(), elsewhere: true),
            Debt(sourceId: photos.id, destinationId: hdd.id, since: Date(), elsewhere: false),
        ]
        state.lastDelivered[AppState.deliveryKey(sourceId: notes.id, destinationId: ssd.id)] = "2026-10-01_10-00-00"
        let caughtUp = Date.wholeSeconds(-86_400)
        state.updateDestination(ssd.id) { $0.lastCaughtUp = caughtUp }
        try await fixture.use(Config(sources: [notes, photos], destinations: [hdd, ssd, cloud]), state: state)
        let model = fixture.model

        #expect(model.isWaiting(notes, for: hdd))
        #expect(!model.isWaiting(notes, for: ssd))
        #expect(model.isCoveredElsewhere(notes, for: hdd))
        #expect(!model.isCoveredElsewhere(photos, for: hdd))
        #expect(model.isCoveredElsewhere(notes, for: ssd))
        #expect(model.otherCopies(of: notes, besides: hdd) == [ssd])
        #expect(model.waitingSources(for: hdd) == [notes, photos])
        #expect(model.waitingSources(for: ssd).isEmpty)
        #expect(model.lastCaughtUp(ssd) == caughtUp)
        #expect(model.lastCaughtUp(hdd) == nil)
        #expect(model.connectDeadline(of: hdd) != nil)
        #expect(model.connectDeadline(of: ssd) == nil)
        #expect(model.chain(of: notes.id) == nil)
    }

    @Test func disconnectedDiskIsShownAsOffline() async throws {
        let fixture = try ModelFixture()
        let hdd = try fixture.disk("HDD", connected: false)
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
        #expect(await eventually { model.destinationSharing[disk.id] != nil })
        #expect(model.freeSpace.map { $0 > 0 } == true)

        let reopened = AppModel(
            dataDirectory: fixture.store.dataDirectory,
            workDirectory: fixture.workDirectory,
            rclone: RcloneLocator(candidates: []),
            defaults: fixture.defaults.defaults
        )
        #expect(reopened.destinationUsage == model.destinationUsage)
        #expect(reopened.destinationSharing == model.destinationSharing)
    }

    @Test func rememberedSizesIgnoreEntriesThatAreNotDisks() throws {
        let defaults = TestDefaults()
        let disk = UUID()
        defaults.defaults.set([disk.uuidString: Int64(42), "junk": Int64(7)], forKey: "destinationUsage")
        defaults.defaults.set([disk.uuidString: false, "junk": true], forKey: "destinationSharing")
        let temp = try TemporaryFolder()
        let model = AppModel(
            dataDirectory: temp.url.appendingPathComponent("data"),
            workDirectory: temp.url.appendingPathComponent("work"),
            rclone: RcloneLocator(candidates: []),
            defaults: defaults.defaults
        )
        #expect(model.destinationUsage == [disk: 42])
        #expect(model.destinationSharing == [disk: false])
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
