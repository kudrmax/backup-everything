import Foundation
import Testing
@testable import BackupCore

/// Copies are proven only at a place that can be verified (5.3.1). A folder on an external disk without a confirmed disk
/// is not such a place: any disk can be plugged in there. It holds no facts, and the facts an older version left there
/// are forgotten, as at a move; they are learned again only once the disk is confirmed and checked.
struct UnverifiablePlaceTests {
    private let temp: TempDirectory
    private let time: FakeTimeSource
    private let store: Store
    private let disks: FakeDisks
    private let coordinator: BackupCoordinator
    private let now = Fixtures.date("2026-10-06 12:00:00")
    private let realDisk = DiskIdentity(uuid: "11111111-AAAA-4AAA-8AAA-111111111111", name: "TEST-BE-HDD")

    init() throws {
        let temp = try TempDirectory()
        self.temp = temp
        time = FakeTimeSource(now)
        store = Store(dataDirectory: temp.path("data"))
        try temp.file("vault/a.md", "alpha")
        try temp.directory("trash")
        try temp.directory("hdd")
        disks = FakeDisks(.connected(realDisk))
        let trash: ManualExportInbox.Trash = { url in try FileManager.default.moveItem(at: url, to: temp.path("trash/\(UUID().uuidString)")) }
        let inbox = ManualExportInbox(pendingRoot: temp.path("work/pending"), naming: Fixtures.naming, trash: trash)
        let runner = SystemProcessRunner()
        let stores = DefaultDestinationStoreFactory(runner: runner, rclone: RcloneLocator(), naming: Fixtures.naming, disks: disks)
        coordinator = BackupCoordinator(
            store: store,
            engine: BackupEngine(
                providers: DefaultSourceProviderFactory(runner: runner, stagingRoot: temp.path("work/staging"), inbox: inbox, trash: trash),
                stores: stores,
                retention: RetentionPolicy(timeZone: Fixtures.utc),
                naming: Fixtures.naming,
                time: time
            ),
            inbox: inbox,
            chains: StepChainRunner(chainsRoot: temp.path("work/chains"), inbox: inbox, runner: runner, time: time, trash: trash),
            stores: stores,
            time: time,
            calendar: Fixtures.calendar
        )
    }

    /// State as an older version left it: copies named and in the history, no dates, no places, never reconciled.
    private func writeLegacyState(_ sources: [Source], hdd: Destination, copiedAt: Date, change: (inout AppState) -> Void = { _ in }) throws {
        var state = AppState()
        for source in sources {
            state.updateSource(source.id) { $0.lastRun = copiedAt; $0.lastSuccess = copiedAt }
            state.recordDelivery(sourceId: source.id, destinationId: hdd.id, snapshotName: Fixtures.naming.name(for: copiedAt), collectedAt: copiedAt)
            try store.appendRun(RunRecord(
                sourceId: source.id, sourceName: source.name, trigger: .scheduled, startedAt: copiedAt, finishedAt: copiedAt,
                snapshotName: Fixtures.naming.name(for: copiedAt), collectedAt: copiedAt,
                deliveries: [Delivery(destinationId: hdd.id, destinationName: hdd.name, outcome: .delivered(pruned: 0, warning: nil))]
            ))
        }
        change(&state)
        state.deliveredAt = nil
        state.expectedSince = nil
        for key in state.destinations.keys { state.destinations[key]?.location = nil }
        try store.saveState(state)
        let text = try String(contentsOf: temp.path("data/state.json"), encoding: .utf8)
        #expect(!text.contains("deliveredAt") && !text.contains("expectedSince") && !text.contains("location"))
    }

    private func sources(to hdd: Destination) -> [Source] {
        (1...4).map { i in
            Fixtures.source(
                name: "S\(i)", steps: [.folder(temp.path("vault").path, excludes: [])], schedule: .weekly,
                destinations: [hdd], createdAt: Fixtures.date("2026-01-01 00:00:00")
            )
        }
    }

    @Test(arguments: [ExpectedEvery.days(14), ExpectedEvery.always], [true, false])
    func olderFactsOnAnUnconfirmedDiskAreNotTrusted(rhythm: ExpectedEvery, attached: Bool) async throws {
        defer { temp.remove() }
        disks.location = attached ? .connected(realDisk) : .notConnected
        var hdd = Fixtures.localDestination("HDD", at: temp.path("hdd"), expectedEvery: rhythm)
        let sources = sources(to: hdd)
        try store.saveConfig(Config(sources: sources, destinations: [hdd]))
        try writeLegacyState(sources, hdd: hdd, copiedAt: now.addingTimeInterval(-2 * 86400))

        let before = try await coordinator.currentStatus()
        #expect(before.report.fresh.isEmpty)
        #expect(before.report.expected == Set(sources.map(\.id)))
        #expect(before.report.overall != .ok)
        for source in sources {
            #expect(before.state.deliveredCopyDate(sourceId: source.id, destinationId: hdd.id) == nil)
            #expect(before.state.lastDeliveredSnapshot(sourceId: source.id, destinationId: hdd.id) == nil)
            #expect(before.state.copyExpectedSince(sourceId: source.id, destinationId: hdd.id) == now)
            #expect(before.report.items.contains(.copiesOutdated(sourceId: source.id, OutdatedCopies(
                destinationIds: [hdd.id], freshElsewhere: false, noCopyAnywhere: true
            ))))
            #expect(!before.report.items.contains(.severelyOverdue(sourceId: source.id)))
        }
        #expect(try await coordinator.nextWake() == now.addingTimeInterval(SchedulePlanner.retryInterval))

        let firstTick = try await coordinator.tick()
        #expect(firstTick.runs.isEmpty)
        #expect(try await coordinator.currentStatus().report.fresh.isEmpty)
        #expect(temp.names(in: "hdd").isEmpty)

        disks.location = .connected(realDisk)
        hdd.disk = realDisk
        try store.saveConfig(Config(sources: sources, destinations: [hdd]))
        time.advance(600)
        let confirmed = try await coordinator.currentStatus()
        #expect(confirmed.report.fresh.isEmpty)
        #expect(sources.allSatisfy { confirmed.state.copyExpectedSince(sourceId: $0.id, destinationId: hdd.id) == time.now })

        let catchUp = try await coordinator.tick()
        #expect(catchUp.runs.map(\.trigger) == Array(repeating: .catchUp, count: 4))
        #expect(catchUp.notices.isEmpty)
        let done = try await coordinator.currentStatus()
        #expect(done.report.fresh.count == 4)
        #expect(done.report.overall == .ok)

        time.advance(600)
        #expect(try await coordinator.tick() == TickResult())
        #expect(try await coordinator.currentStatus().report.overall == .ok)
    }

    /// The disk confirmed right after the update, before any backup check ran: what was only looked at is already
    /// forgotten, so the confirmed disk does not inherit it.
    @Test func confirmingBeforeAnyCheckDoesNotAdoptOlderFacts() async throws {
        defer { temp.remove() }
        var hdd = Fixtures.localDestination("HDD", at: temp.path("hdd"), expectedEvery: .days(14))
        let sources = sources(to: hdd)
        try store.saveConfig(Config(sources: sources, destinations: [hdd]))
        try writeLegacyState(sources, hdd: hdd, copiedAt: now.addingTimeInterval(-2 * 86400))
        #expect(try await coordinator.currentStatus().report.fresh.isEmpty)

        hdd.disk = realDisk
        try store.saveConfig(Config(sources: sources, destinations: [hdd]))
        let confirmed = try await coordinator.currentStatus()
        #expect(confirmed.report.fresh.isEmpty)
        #expect(!confirmed.state.knowsCopies(at: hdd.id))
        let catchUp = try await coordinator.tick()
        #expect(catchUp.runs.map(\.trigger) == Array(repeating: .catchUp, count: 4))
        #expect(try await coordinator.currentStatus().report.overall == .ok)
    }

    /// Every action that saves the state saves it reconciled, so no older fact slips back through a side door.
    @Test(arguments: [false, true])
    func actionsOnAWaitingSourceSaveTheReconciledState(restart: Bool) async throws {
        defer { temp.remove() }
        let hdd = Fixtures.localDestination("HDD", at: temp.path("hdd"), expectedEvery: .days(14))
        let source = sources(to: hdd)[0]
        try store.saveConfig(Config(sources: [source], destinations: [hdd]))
        try writeLegacyState([source], hdd: hdd, copiedAt: now.addingTimeInterval(-2 * 86400))

        _ = restart ? try await coordinator.restartChain(sourceId: source.id) : try await coordinator.cancelWaiting(sourceId: source.id)
        let saved = try store.loadState()
        #expect(!saved.knowsCopies(at: hdd.id))
        #expect(saved.copyExpectedSince(sourceId: source.id, destinationId: hdd.id) == now)
        #expect(saved.destinationState(hdd.id).location == hdd.location)
    }

    /// A debt says a newer copy is owed, not that the named one is gone: a vanished copy loses its name when the check
    /// finds it missing. So the age of a named copy is learned even while a newer one is owed.
    @Test func namedCopyKeepsItsDateWhileANewerOneIsOwed() async throws {
        defer { temp.remove() }
        disks.location = .notConnected
        var hdd = Fixtures.localDestination("HDD", at: temp.path("hdd"), expectedEvery: .days(14))
        hdd.disk = realDisk
        let source = sources(to: hdd)[0]
        let copiedAt = now.addingTimeInterval(-5 * 86400)
        try store.saveConfig(Config(sources: [source], destinations: [hdd]))
        try writeLegacyState([source], hdd: hdd, copiedAt: copiedAt) { state in
            state.updateSource(source.id) { $0.lastRun = self.now.addingTimeInterval(-2 * 86400) }
            state.debts.append(Debt(sourceId: source.id, destinationId: hdd.id, since: self.now.addingTimeInterval(-2 * 86400), elsewhere: false))
        }

        let status = try await coordinator.currentStatus()
        #expect(status.state.deliveredCopyDate(sourceId: source.id, destinationId: hdd.id) == copiedAt)
        #expect(!status.report.items.contains(.severelyOverdue(sourceId: source.id)))
        #expect(status.report.items.contains(.copiesOutdated(sourceId: source.id, OutdatedCopies(
            destinationIds: [hdd.id], freshElsewhere: false, noCopyAnywhere: false
        ))))
        #expect(status.report.overall == .attention)
    }
}
