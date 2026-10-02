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
        #expect(diskStore.log == ["write:\(name)", "removeIncomplete"])
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
        #expect(!diskStore.log.contains("removeIncomplete"))
        #expect(provider.finished == [false])
    }

    @Test func prunesByRetentionOnlyAfterSuccessfulWrite() async {
        defer { temp.remove() }
        cloudStore.snapshots = ["2026-09-25 10:00:00", "2026-09-26 10:00:00", "2026-09-27 10:00:00"].map(Fixtures.snapshot)
        let record = await run()
        #expect(record.deliveries[1].outcome == .delivered(pruned: 2, warning: nil))
        #expect(cloudStore.log == ["write:\(name)", "removeIncomplete", "delete:2026-09-25_100000", "delete:2026-09-26_100000"])
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

    private func engine(_ stores: any DestinationStoreFactory) -> BackupEngine {
        BackupEngine(
            providers: FakeFactories(sourceProvider: provider, destinationStores: [:]),
            stores: stores,
            retention: RetentionPolicy(timeZone: Fixtures.utc),
            naming: Fixtures.naming,
            time: FakeTimeSource(now),
            progress: { [events] event in events.set(events.get() + [event]) }
        )
    }

    private var fakeStores: FakeFactories {
        FakeFactories(sourceProvider: provider, destinationStores: [disk.id: diskStore, cloud.id: cloudStore])
    }

    private func materializedCopy() throws -> URL {
        try temp.file("hdd-copy/\(name)/a.md", "alpha")
        try temp.file("hdd-copy/\(name)/sub/b.md", "beta")
        try temp.file("hdd-copy/\(name)/_snapshot.json", "{}")
        return temp.path("hdd-copy/\(name)")
    }

    @Test func catchUpTransfersTheExistingCopyUnderItsOwnName() async throws {
        defer { temp.remove() }
        diskStore.materialized = try materializedCopy()
        let snapshot = Snapshot(name: name, date: now)

        let record = await engine(fakeStores).copy(snapshot, of: source, from: disk, to: [cloud])

        #expect(provider.collectCount == 0)
        #expect(record.trigger == .catchUp)
        #expect(record.snapshotName == name)
        #expect(record.collectedAt == now)
        #expect(record.copiedFrom == "HDD")
        #expect(record.details == "Copied from “HDD”")
        #expect(record.fileCount == 2)
        #expect(record.totalBytes == 9)
        #expect(record.deliveries.map(\.outcome) == [.delivered(pruned: 0, warning: nil)])
        #expect(cloudStore.log == ["write:\(name)", "removeIncomplete"])
        #expect(cloudStore.writtenManifests.map(\.fileCount) == [2])
        #expect(cloudStore.writtenManifests.first?.sourceId == source.id)
        #expect(cloudStore.writtenPayloads.first?.excludedAtTop == SnapshotManifest.serviceFileNames)
        #expect(events.get() == [.delivering(sourceId: source.id, destinationId: cloud.id), .finished(sourceId: source.id)])
    }

    @Test func catchUpSkipsUnavailableTargets() async throws {
        defer { temp.remove() }
        diskStore.materialized = try materializedCopy()
        let laptop = Destination(name: "Laptop", kind: .localFolder(path: "/unused/laptop"))
        let laptopStore = FakeDestinationStore()
        laptopStore.available = false
        let stores = FakeFactories(sourceProvider: provider, destinationStores: [disk.id: diskStore, cloud.id: cloudStore, laptop.id: laptopStore])

        let record = await engine(stores).copy(Snapshot(name: name, date: now), of: source, from: disk, to: [laptop, cloud])

        #expect(record.deliveries.map(\.outcome) == [.unavailable, .delivered(pruned: 0, warning: nil)])
        #expect(laptopStore.log.isEmpty)
    }

    @Test func catchUpFromAnOriginThatCannotGiveTheCopyFailsEveryTarget() async {
        defer { temp.remove() }
        let record = await engine(fakeStores).copy(Snapshot(name: name, date: now), of: source, from: disk, to: [cloud])
        #expect(record.deliveries.map(\.outcome) == [.failed(message: "Could not take the copy from “HDD”: The destination is unavailable.")])
        #expect(record.snapshotName == nil)
        #expect(cloudStore.log.isEmpty)
        #expect(events.get() == [.finished(sourceId: source.id)])
    }

    @Test func caughtUpOlderCopyIsNotPrunedByItsOwnDelivery() async throws {
        defer { temp.remove() }
        diskStore.materialized = try materializedCopy()
        cloudStore.snapshots = ["2026-09-26 10:00:00", "2026-09-27 10:00:00", "2026-09-28 20:00:00"].map(Fixtures.snapshot)

        let record = await engine(fakeStores).copy(Snapshot(name: name, date: now), of: source, from: disk, to: [cloud])

        #expect(record.deliveries.map(\.outcome) == [.delivered(pruned: 1, warning: nil)])
        #expect(cloudStore.snapshots.map(\.name).sorted() == ["2026-09-27_100000", name, "2026-09-28_200000"])
    }

    @Test func destinationThatCannotListItsCopiesIsNotWrittenTo() async {
        defer { temp.remove() }
        cloudStore.listError = Boom()
        let record = await run()
        #expect(record.deliveries.map(\.outcome) == [.delivered(pruned: 0, warning: nil), .failed(message: "disk disconnected")])
        #expect(cloudStore.log.isEmpty)
        #expect(provider.finished == [false])
    }

    @Test func failedCleanupOfUnfinishedCopiesPrunesNothing() async {
        defer { temp.remove() }
        cloudStore.snapshots = ["2026-09-25 10:00:00", "2026-09-26 10:00:00", "2026-09-27 10:00:00"].map(Fixtures.snapshot)
        cloudStore.removeIncompleteError = Boom()
        let record = await run()
        #expect(record.deliveries[1].outcome == .delivered(pruned: 0, warning: "Could not clean up old copies: disk disconnected"))
        #expect(cloudStore.snapshots.count == 4)
        #expect(provider.finished == [true])
    }

    private struct TrashingLocalStores: DestinationStoreFactory {
        let trash: URL

        func store(for destination: Destination) -> any DestinationStore {
            guard case let .localFolder(path) = destination.kind else { fatalError("local folders only") }
            return LocalFolderDestination(root: URL(fileURLWithPath: path), naming: Fixtures.naming) { url in
                try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
            }
        }
    }

    @Test func realDiskKeepsByRuleTrashesOnlyUnfinishedAndLeavesForeignFoldersAlone() async throws {
        defer { temp.remove() }
        try temp.directory("Trash")
        for day in ["2026-09-24_100000", "2026-09-25_100000", "2026-09-26_100000", "2026-09-27_100000"] {
            try temp.file("hdd/obsidian/\(day)/a.md", "old")
            try temp.file("hdd/obsidian/\(day)/_snapshot.json", "{}")
        }
        try temp.file("hdd/obsidian/2026-09-28_120000/_unfinished")
        try temp.file("hdd/obsidian/2026-09-28_120000/a.md", "half")
        try temp.file("hdd/obsidian/2026-09-23_100000/lost-manifest.md")
        try temp.file("hdd/obsidian/Мои вещи/keep.md")
        let hdd = Fixtures.localDestination("HDD", at: temp.path("hdd"))
        let source = Fixtures.source(retention: RetentionRules(daily: 2, weekly: 0, monthly: 0, yearly: 0), destinations: [hdd])

        let record = await engine(TrashingLocalStores(trash: temp.path("Trash"))).run(source: source, destinations: [hdd], trigger: .scheduled)

        #expect(record.deliveries.map(\.outcome) == [.delivered(pruned: 3, warning: nil)])
        #expect(temp.names(in: "hdd/obsidian") == ["2026-09-23_100000", "2026-09-27_100000", name, "Мои вещи"])
        #expect(temp.names(in: "Trash") == ["2026-09-28_120000"])
        #expect(try String(contentsOf: temp.path("hdd/obsidian/\(name)/a.md"), encoding: .utf8) == "alpha")
    }

    @Test func realDiskThatFailsMidWriteKeepsEveryOlderCopy() async throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temp.path("vault/secret.md").path)
            temp.remove()
        }
        try temp.directory("Trash")
        for day in ["2026-09-25_100000", "2026-09-26_100000", "2026-09-27_100000"] {
            try temp.file("hdd/obsidian/\(day)/_snapshot.json", "{}")
        }
        try temp.file("vault/secret.md", "no access")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: temp.path("vault/secret.md").path)
        let hdd = Fixtures.localDestination("HDD", at: temp.path("hdd"))
        let source = Fixtures.source(retention: RetentionRules(daily: 1, weekly: 0, monthly: 0, yearly: 0), destinations: [hdd])

        let record = await engine(TrashingLocalStores(trash: temp.path("Trash"))).run(source: source, destinations: [hdd], trigger: .scheduled)

        #expect(record.firstFailure != nil)
        #expect(temp.names(in: "hdd/obsidian") == ["2026-09-25_100000", "2026-09-26_100000", "2026-09-27_100000", name])
        #expect(temp.exists("hdd/obsidian/\(name)/_unfinished"))
        #expect(temp.names(in: "Trash").isEmpty)
    }

    @Test func oneCopyThatCannotBeDeletedDoesNotKeepTheOthers() async {
        defer { temp.remove() }
        cloudStore.snapshots = ["2026-09-24 10:00:00", "2026-09-25 10:00:00", "2026-09-26 10:00:00", "2026-09-27 10:00:00"].map(Fixtures.snapshot)
        cloudStore.undeletable = ["2026-09-25_100000"]

        let record = await run()

        let warning = "Could not clean up old copies: \(POSIXError(.EPERM).localizedDescription)"
        #expect(record.deliveries[1].outcome == .delivered(pruned: 2, warning: warning))
        #expect(cloudStore.snapshots.map(\.name).sorted() == ["2026-09-25_100000", "2026-09-27_100000", name])
    }

    @Test func dataNamedLikeTheAppsOwnFileAtTheTopIsACollectError() async throws {
        defer { temp.remove() }
        try temp.file("vault/_snapshot.json", "{}")

        let record = await run()

        #expect(record.collectError == SourceError.reservedName("_snapshot.json").localizedDescription)
        #expect(record.deliveries.isEmpty)
        #expect(diskStore.log.isEmpty)
        #expect(provider.finished == [false])
    }

    @Test func catchUpCopyKeepsTheSourcesFilesNamedLikeTheAppsOwnOnes() async throws {
        defer { temp.remove() }
        try temp.directory("hdd")
        try temp.directory("ssd")
        try temp.file("hdd/obsidian/\(name)/_snapshot.json", "{}")
        try temp.file("hdd/obsidian/\(name)/a.md", "alpha")
        try temp.file("hdd/obsidian/\(name)/projects/site/_snapshot.json", "{\"page\": 1}")
        try temp.file("hdd/obsidian/\(name)/notes/_unfinished", "a note called _unfinished")
        let hdd = Fixtures.localDestination("HDD", at: temp.path("hdd"))
        let ssd = Fixtures.localDestination("SSD", at: temp.path("ssd"))

        let record = await engine(TrashingLocalStores(trash: temp.path("Trash"))).copy(Snapshot(name: name, date: now), of: source, from: hdd, to: [ssd])

        #expect(record.deliveries.map(\.outcome.isDelivered) == [true])
        #expect(record.fileCount == 3)
        let copied = "ssd/obsidian/\(name)"
        #expect(try String(contentsOf: temp.path(copied + "/projects/site/_snapshot.json"), encoding: .utf8) == "{\"page\": 1}")
        #expect(temp.exists(copied + "/notes/_unfinished"))
        #expect(!temp.exists(copied + "/_unfinished"))
    }
}
