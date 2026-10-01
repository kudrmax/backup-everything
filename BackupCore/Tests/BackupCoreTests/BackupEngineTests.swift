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
            retention: RetentionPolicy(timeZone: Fixtures.utc),
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
        #expect(diskStore.log == ["removeIncomplete", "write:\(name)"])
        #expect(provider.finished == [true])
    }

    @Test func destinationsAreToldWhetherTheSourceSavesSpace() async {
        defer { temp.remove() }
        _ = await run()
        var frugal = source
        frugal.savesSpace = false
        _ = await run(source: frugal)
        #expect(diskStore.reusedStoredFiles == [true])
        diskStore.snapshots = []
        _ = await run(source: frugal)
        #expect(diskStore.reusedStoredFiles == [true, false])
    }

    @Test func unavailableDestinationDoesNotBlockOthers() async {
        defer { temp.remove() }
        diskStore.available = false
        let record = await run()
        #expect(record.deliveries.map(\.outcome) == [.unavailable, .delivered(pruned: 0, warning: nil)])
        #expect(diskStore.log.isEmpty)
        #expect(provider.finished == [false])
    }

    @Test func nothingIsCollectedWhenNoDestinationIsReachable() async {
        defer { temp.remove() }
        diskStore.available = false
        cloudStore.available = false
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

    @Test func emptySourceNeverProducesSnapshotOrPrunesOldOnes() async throws {
        defer { temp.remove() }
        try temp.directory("emptied")
        provider.result = .success(Payload(root: temp.path("emptied"), collectedAt: now))
        cloudStore.snapshots = ["2026-09-25 10:00:00", "2026-09-26 10:00:00", "2026-09-27 10:00:00"].map(Fixtures.snapshot)
        let record = await run()
        #expect(record.collectError == SourceError.emptyResult.localizedDescription)
        #expect(cloudStore.snapshots.count == 3)
        #expect(cloudStore.log.isEmpty)
        #expect(provider.finished == [false])
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
        #expect(provider.finished == [false])
    }

    @Test func writeFailureIsIsolatedAndSkipsPruning() async {
        defer { temp.remove() }
        diskStore.writeError = Boom()
        diskStore.snapshots = ["2026-09-25 10:00:00", "2026-09-26 10:00:00", "2026-09-27 10:00:00"].map(Fixtures.snapshot)
        let record = await run()
        #expect(record.deliveries.map(\.outcome) == [.failed(message: "disk disconnected"), .delivered(pruned: 0, warning: nil)])
        #expect(record.firstFailure == "disk disconnected")
        #expect(diskStore.snapshots.count == 3)
        #expect(provider.finished == [false])
    }

    @Test func prunesByRetentionOnlyAfterSuccessfulWrite() async {
        defer { temp.remove() }
        cloudStore.snapshots = ["2026-09-25 10:00:00", "2026-09-26 10:00:00", "2026-09-27 10:00:00"].map(Fixtures.snapshot)
        let record = await run()
        #expect(record.deliveries[1].outcome == .delivered(pruned: 2, warning: nil))
        #expect(cloudStore.log == ["removeIncomplete", "write:\(name)", "delete:2026-09-25_100000", "delete:2026-09-26_100000"])
        #expect(cloudStore.snapshots.map(\.name) == ["2026-09-27_100000", name])
    }

    @Test func pruneFailureKeepsDeliveryButWarns() async {
        defer { temp.remove() }
        cloudStore.snapshots = ["2026-09-25 10:00:00", "2026-09-26 10:00:00"].map(Fixtures.snapshot)
        cloudStore.deleteError = Boom()
        let record = await run()
        #expect(record.deliveries[1].outcome == .delivered(pruned: 0, warning: "Could not clean up old copies: disk disconnected"))
        #expect(record.firstFailure == nil)
    }

    @Test func alreadyDeliveredSnapshotIsNotWrittenTwice() async {
        defer { temp.remove() }
        cloudStore.snapshots = [Snapshot(name: name, date: now)]
        let record = await run(.catchUp)
        #expect(record.deliveries[1].outcome == .delivered(pruned: 0, warning: nil))
        #expect(cloudStore.log == ["removeIncomplete"])
    }

    @Test func freshlyWrittenSnapshotIsNeverPrunedEvenIfOlderThanExisting() async {
        defer { temp.remove() }
        cloudStore.snapshots = [Fixtures.snapshot("2026-09-28 20:00:00")]
        let record = await run()
        #expect(record.deliveries[1].outcome == .delivered(pruned: 0, warning: nil))
        #expect(cloudStore.snapshots.map(\.name).sorted() == [name, "2026-09-28_200000"])
    }

    @Test func reportsEachStageOfTheRun() async {
        defer { temp.remove() }
        diskStore.available = false
        _ = await run()
        #expect(events.get() == [
            .collecting(sourceId: source.id),
            .delivering(sourceId: source.id, destinationId: cloud.id),
            .finished(sourceId: source.id),
        ])
    }

    @Test func reportsFinishEvenWhenNothingWasDone() async {
        defer { temp.remove() }
        diskStore.available = false
        cloudStore.available = false
        _ = await run()
        #expect(events.get() == [.finished(sourceId: source.id)])

        events.set([])
        cloudStore.available = true
        provider.result = .failure(SourceError.emptyResult)
        _ = await run()
        #expect(events.get() == [.collecting(sourceId: source.id), .finished(sourceId: source.id)])
    }
}
