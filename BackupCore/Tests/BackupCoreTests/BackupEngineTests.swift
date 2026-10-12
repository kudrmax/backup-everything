import Foundation
import Testing
@testable import BackupCore

struct BackupEngineTests {
    private struct Boom: Error, LocalizedError {
        var errorDescription: String? { "disk disconnected" }
    }

    private let temp: TempDirectory
    private let now = Fixtures.date("2026-09-28 14:30:00")
    private let name = "2026-09-28_143000"
    private let disk = Destination(name: "HDD", kind: .localFolder(path: "/unused/hdd"))
    private let cloud = Destination(name: "Cloud", kind: .localFolder(path: "/unused/cloud"))
    private let diskStore = FakeDestinationStore()
    private let cloudStore = FakeDestinationStore()
    private let provider: FakeSourceProvider
    private let events = LockedBox<[RunProgress]>([])
    private let source: Source

    init() throws {
        temp = try TempDirectory()
        try temp.file("vault/a.md", "alpha")
        provider = FakeSourceProvider(result: .success(Payload(root: temp.path("vault"), collectedAt: now, details: "log tail")))
        source = Fixtures.source(retention: RetentionRules(daily: 2, weekly: 0, monthly: 0, yearly: 0), destinations: [disk, cloud])
    }

    private func run(_ trigger: RunTrigger = .scheduled, source: Source? = nil) async -> RunRecord {
        let factories = FakeFactories(sourceProvider: provider, destinationStores: [disk.id: diskStore, cloud.id: cloudStore])
        let engine = BackupEngine(
            providers: factories,
            stores: factories,
            naming: Fixtures.naming,
            time: FakeTimeSource(now),
            progress: { [events] event in events.set(events.get() + [event]) }
        )
        return await engine.run(source: source ?? self.source, destinations: [disk, cloud], trigger: trigger)
    }

    @Test func deliversSnapshotToEveryDestination() async {
        defer { temp.remove() }
        let record = await run()
        #expect(record.snapshotName == name)
        #expect(record.collectedAt == now)
        #expect(record.fileCount == 1)
        #expect(record.totalBytes == 5)
        #expect(record.details == "log tail")
        #expect(record.collectError == nil)
        #expect(record.deliveries.map(\.outcome) == [.delivered(pruned: 0, warning: nil), .delivered(pruned: 0, warning: nil)])
        #expect(diskStore.log == ["write:\(name)"])
        #expect(provider.finished == [.everywhere])
    }

    /// Whether a run delivers a copy made before it is a fact of the run, not a guess from the copy's date.
    @Test(arguments: [
        (RunTrigger.pickup, true, true),
        (RunTrigger.pickup, false, false),
        (RunTrigger.scheduled, false, false),
    ])
    func runKnowsWhetherItDeliversACopyMadeEarlier(trigger: RunTrigger, madeEarlier: Bool, older: Bool) async {
        defer { temp.remove() }
        provider.result = .success(Payload(root: temp.path("vault"), collectedAt: now.addingTimeInterval(7200), madeEarlier: madeEarlier))
        #expect(await run(trigger).deliversAnOlderCopy == older)
    }

    @Test func unavailableDestinationDoesNotBlockOthers() async {
        defer { temp.remove() }
        diskStore.readinessValue = .folderMissing
        let record = await run()
        #expect(record.deliveries.map(\.outcome) == [.unavailable, .delivered(pruned: 0, warning: nil)])
        #expect(diskStore.log.isEmpty)
        #expect(provider.finished == [.partly])
    }

    @Test func destinationThatIsNotSetUpIsNotWrittenTo() async {
        defer { temp.remove() }
        diskStore.readinessValue = .notOwnedByBackupAccount(owner: "max")
        let record = await run()
        #expect(record.deliveries.map(\.outcome) == [.unavailable, .delivered(pruned: 0, warning: nil)])
        #expect(diskStore.log.isEmpty)
    }

    @Test func nothingIsCollectedWhenNoDestinationIsReachable() async {
        defer { temp.remove() }
        diskStore.readinessValue = .folderMissing
        cloudStore.readinessValue = .folderMissing
        let record = await run()
        #expect(record.deliveries.map(\.outcome) == [.unavailable, .unavailable])
        #expect(record.isDeferredOnly)
        #expect(provider.collectCount == 0)
    }

    @Test func collectFailureWritesNothing() async {
        defer { temp.remove() }
        provider.result = .failure(SourceError.commandFailed(exitCode: 1, output: "auth required"))
        let record = await run()
        #expect(record.collectError == "Command exited with code 1. auth required")
        #expect(record.deliveries.isEmpty)
        #expect(cloudStore.log.isEmpty)
    }

    @Test func emptySourceNeverProducesSnapshot() async throws {
        defer { temp.remove() }
        try temp.directory("emptied")
        provider.result = .success(Payload(root: temp.path("emptied"), collectedAt: now))
        cloudStore.snapshots = ["2026-09-25 10:00:00", "2026-09-26 10:00:00", "2026-09-27 10:00:00"].map(Fixtures.snapshot)
        let record = await run()
        #expect(record.collectError == SourceError.emptyResult.localizedDescription)
        #expect(cloudStore.snapshots.count == 3)
        #expect(cloudStore.log.isEmpty)
        #expect(provider.finished == [.nowhere])
    }

    @Test func workFolderThatCannotBeClearedIsReportedWithTheDeliveries() async {
        defer { temp.remove() }
        provider.finishError = Boom()
        diskStore.writeError = Boom()
        let record = await run()
        #expect(record.deliveries.map(\.outcome) == [
            .failed(message: "disk disconnected Could not clear the work folder: disk disconnected"),
            .delivered(pruned: 0, warning: "Could not clear the work folder: disk disconnected"),
        ])
    }

    @Test func workFolderThatCannotBeClearedAfterAFailedCollectIsReported() async throws {
        defer { temp.remove() }
        try temp.directory("emptied")
        provider.result = .success(Payload(root: temp.path("emptied"), collectedAt: now))
        provider.finishError = Boom()
        let record = await run()
        #expect(record.collectError == "\(SourceError.emptyResult.localizedDescription) Could not clear the work folder: disk disconnected")
    }

    @Test func passesStatusFromTheSourceWhileCollecting() async {
        defer { temp.remove() }
        provider.statuses = ["1 of 2", "2 of 2"]
        _ = await run()
        #expect(Array(events.get().prefix(3)) == [
            .collecting(sourceId: source.id),
            .status(sourceId: source.id, text: "1 of 2"),
            .status(sourceId: source.id, text: "2 of 2"),
        ])
    }

    @Test func collectedResultIsReleasedEvenWhenItCannotBeRead() async {
        defer { temp.remove() }
        provider.result = .success(Payload(root: temp.path("vanished"), collectedAt: now))
        let record = await run()
        #expect(record.collectError == SourceError.pathMissing(temp.path("vanished").path).localizedDescription)
        #expect(record.deliveries.isEmpty)
        #expect(provider.finished == [.nowhere])
    }

    @Test func writeFailureIsIsolated() async {
        defer { temp.remove() }
        diskStore.writeError = Boom()
        diskStore.snapshots = ["2026-09-25 10:00:00", "2026-09-26 10:00:00", "2026-09-27 10:00:00"].map(Fixtures.snapshot)
        let record = await run()
        #expect(record.deliveries.map(\.outcome) == [.failed(message: "disk disconnected"), .delivered(pruned: 0, warning: nil)])
        #expect(record.firstFailure == "disk disconnected")
        #expect(diskStore.snapshots.count == 3)
        #expect(diskStore.log.isEmpty)
        #expect(provider.finished == [.partly])
    }

    /// A destination that holds a copy at least as new as the collected data already has the package.
    @Test func deliversOnlyWhereTheCopyIsMissing() async {
        defer { temp.remove() }
        cloudStore.snapshots = [Fixtures.snapshot("2026-09-28 14:30:00")]
        diskStore.snapshots = [Fixtures.snapshot("2026-09-28 14:29:59")]
        let record = await run(.pickup)
        #expect(record.deliveries.map(\.outcome) == [.delivered(pruned: 0, warning: nil), .delivered(pruned: 0, warning: nil)])
        #expect(diskStore.log == ["write:\(name)"])
        #expect(cloudStore.log.isEmpty)
    }

    /// A package kept in pending is written under the time of this run, and only where no copy as new as it is yet.
    @Test func pendingPackageIsNamedByTheRunAndSkippedWhereANewerCopyIs() async {
        defer { temp.remove() }
        let collected = Fixtures.date("2026-09-25 09:00:00")
        provider.result = .success(Payload(root: temp.path("vault"), collectedAt: collected, madeEarlier: true))
        cloudStore.snapshots = [Fixtures.snapshot("2026-09-26 10:00:00")]
        diskStore.snapshots = [Fixtures.snapshot("2026-09-20 10:00:00")]
        let record = await run(.catchUp)
        #expect(record.snapshotName == name)
        #expect(record.collectedAt == collected)
        #expect(record.deliveries.map(\.outcome) == [.delivered(pruned: 0, warning: nil), .delivered(pruned: 0, warning: nil)])
        #expect(diskStore.log == ["write:\(name)"])
        #expect(cloudStore.log.isEmpty)
    }

    /// When clocks go back, the hour repeats: two backups an hour apart are two copies, the second is not taken for “already delivered”.
    @Test func backupInTheRepeatedHourIsNotLost() async throws {
        defer { temp.remove() }
        let berlin = SnapshotNaming(timeZone: TimeZone(identifier: "Europe/Berlin")!)
        let first = Fixtures.date("2026-10-25 00:30:00")
        let second = Fixtures.date("2026-10-25 01:30:00")
        try temp.file("vault/a.md", "alpha")
        let provider = FakeSourceProvider(result: .success(Payload(root: temp.path("vault"), collectedAt: first)))
        let disk = Destination(name: "HDD", kind: .localFolder(path: "/unused"))
        let store = FakeDestinationStore()
        let factories = FakeFactories(sourceProvider: provider, destinationStores: [disk.id: store])
        let source = Fixtures.source(destinations: [disk])
        func engine(at now: Date) -> BackupEngine {
            BackupEngine(providers: factories, stores: factories, naming: berlin, time: FakeTimeSource(now))
        }

        _ = await engine(at: first).run(source: source, destinations: [disk], trigger: .manual)
        try temp.file("vault/a.md", "alpha, an hour later")
        provider.result = .success(Payload(root: temp.path("vault"), collectedAt: second))
        _ = await engine(at: second).run(source: source, destinations: [disk], trigger: .manual)

        #expect(store.log.filter { $0.hasPrefix("write:") }.count == 2)
    }

    @Test func olderCopiesAreLeftAsTheyAre() async {
        defer { temp.remove() }
        cloudStore.snapshots = ["2026-09-25 10:00:00", "2026-09-26 10:00:00", "2026-09-27 10:00:00"].map(Fixtures.snapshot)
        let record = await run()
        #expect(record.deliveries[1].outcome == .delivered(pruned: 0, warning: nil))
        #expect(cloudStore.log == ["write:\(name)"])
        #expect(cloudStore.snapshots.count == 4)
    }

    @Test func reportsEachStageOfTheRun() async {
        defer { temp.remove() }
        diskStore.readinessValue = .folderMissing
        _ = await run()
        #expect(events.get() == [
            .collecting(sourceId: source.id),
            .delivering(sourceId: source.id, destinationId: cloud.id),
            .finished(sourceId: source.id),
        ])
    }

    @Test func reportsFinishEvenWhenNothingWasDone() async {
        defer { temp.remove() }
        diskStore.readinessValue = .folderMissing
        cloudStore.readinessValue = .folderMissing
        _ = await run()
        #expect(events.get() == [.finished(sourceId: source.id)])

        events.set([])
        cloudStore.readinessValue = .ready
        provider.result = .failure(SourceError.emptyResult)
        _ = await run()
        #expect(events.get() == [.collecting(sourceId: source.id), .finished(sourceId: source.id)])
    }

    @Test func destinationThatCannotListItsCopiesIsNotWrittenTo() async {
        defer { temp.remove() }
        cloudStore.listError = Boom()
        let record = await run()
        #expect(record.deliveries.map(\.outcome) == [.delivered(pruned: 0, warning: nil), .failed(message: "disk disconnected")])
        #expect(cloudStore.log.isEmpty)
        #expect(provider.finished == [.partly])
    }

    @Test func refusesACompletionMarkerAtTheTop() async throws {
        defer { temp.remove() }
        try temp.file("vault/.complete", "")

        let record = await run()

        #expect(record.collectError?.contains("has the name Backup Everything gives") == true)
        #expect(record.deliveries.isEmpty)
        #expect(diskStore.log.isEmpty)
        #expect(provider.finished == [.nowhere])
    }

    @Test func completionMarkerDeeperInTheSourceIsCopied() async throws {
        defer { temp.remove() }
        try temp.file("vault/notes/.complete", "")
        let record = await run()
        #expect(record.collectError == nil)
        #expect(diskStore.log == ["write:\(name)"])
    }

    @Test func realFolderGetsACompleteCopyLinkedToThePreviousOne() async throws {
        defer { temp.remove() }
        try temp.directory("hdd")
        let hdd = Fixtures.localDestination("HDD", at: temp.path("hdd"))
        let source = Fixtures.source(destinations: [hdd])
        let stores = DefaultDestinationStoreFactory(
            naming: Fixtures.naming,
            access: AlwaysReadyAccess(),
            transfer: RsyncTransfer(rsync: RsyncTransfer.homebrewRsync, receiver: nil, runner: SystemProcessRunner(), scratch: temp.path("scratch"))
        )
        func engine(at now: Date) -> BackupEngine {
            BackupEngine(providers: FakeFactories(sourceProvider: provider, destinationStores: [:]), stores: stores, naming: Fixtures.naming, time: FakeTimeSource(now))
        }

        let first = await engine(at: now).run(source: source, destinations: [hdd], trigger: .scheduled)
        let later = now.addingTimeInterval(86_400)
        provider.result = .success(Payload(root: temp.path("vault"), collectedAt: later))
        let second = await engine(at: later).run(source: source, destinations: [hdd], trigger: .scheduled)

        #expect(first.deliveries.map(\.outcome.isDelivered) == [true])
        #expect(second.deliveries.map(\.outcome.isDelivered) == [true])
        #expect(temp.names(in: "hdd/obsidian") == [name, "2026-09-29_143000"])
        #expect(temp.names(in: "hdd/obsidian/2026-09-29_143000") == [".complete", "a.md"])
        let links = try FileManager.default.attributesOfItem(atPath: temp.path("hdd/obsidian/2026-09-29_143000/a.md").path)[.referenceCount] as? Int
        #expect(links == 2)
    }
}
