import BackupCore
import Foundation
import Testing
@testable import BackupEverything

/// After an update, facts an older version left about a disk that is not confirmed are not trusted anywhere the app
/// shows status: the core does not report them, so nothing here needs a case of its own.
@MainActor
struct UnverifiablePlaceSnapshotTests {
    private let mine = DiskIdentity(uuid: "11111111-AAAA-4AAA-8AAA-111111111111", name: "TEST-BE-A")

    /// State as an older version left it: copies named and in the history, no dates, no places, never reconciled.
    private func legacyState(_ sources: [Source], at hdd: Destination, copiedAt: Date, store: Store) throws -> AppState {
        var state = AppState()
        let naming = SnapshotNaming()
        for source in sources {
            state.updateSource(source.id) { $0.lastRun = copiedAt; $0.lastSuccess = copiedAt }
            state.lastDelivered[AppState.deliveryKey(sourceId: source.id, destinationId: hdd.id)] = naming.name(for: copiedAt)
            try store.appendRun(RunRecord(
                sourceId: source.id, sourceName: source.name, trigger: .scheduled, startedAt: copiedAt, finishedAt: copiedAt,
                snapshotName: naming.name(for: copiedAt), collectedAt: copiedAt,
                deliveries: [Delivery(destinationId: hdd.id, destinationName: hdd.name, outcome: .delivered(pruned: 0, warning: nil))]
            ))
        }
        state.deliveredAt = nil
        return state
    }

    @Test(arguments: [true, false])
    func olderFactsOnAnUnconfirmedDiskLookFineNowhere(attached: Bool) async throws {
        let disks = FakeDisks(attached ? .connected(mine) : .notConnected)
        let fixture = try ModelFixture(disks: disks)
        let hdd = try fixture.disk("HDD", every: 14)
        let sources = try (1...4).map { try fixture.folderSource("S\($0)", to: [hdd], schedule: .weekly) }
        let config = Config(sources: sources, destinations: [hdd])
        let state = try legacyState(sources, at: hdd, copiedAt: Date().addingTimeInterval(-2 * 86400), store: fixture.store)
        try await fixture.use(config, state: state)
        let model = fixture.model
        #expect(await eventually { model.diskChecks[hdd.id] == .notConfirmed(connected: attached ? mine : nil) })

        let snapshot = model.snapshot
        #expect(snapshot.overall != .ok)
        #expect(snapshot.headline(isWorking: false) != "All good")
        #expect(!snapshot.isAllGood)
        for source in sources {
            #expect(snapshot.status(of: source, lastBackup: Date()) != .ok)
            #expect(snapshot.delivery(of: source, to: hdd) != .delivered)
            #expect(snapshot.delivery(of: source, to: hdd).mark != "checkmark.circle.fill")
        }
        guard attached else { return }

        let confirmed = try #require(await model.confirmConnectedDisk(for: hdd))
        #expect(await eventually { model.condition(of: confirmed) == .available })
        #expect(!model.snapshot.isAllGood, "confirming proves nothing by itself")
        await model.tick()
        await fixture.settle()
        #expect(model.snapshot.isAllGood)
        for source in sources {
            #expect(model.snapshot.delivery(of: source, to: confirmed) == .delivered)
        }
    }

    /// A newer copy is owed to an unplugged confirmed disk that holds a named copy: orange, not red, and the copy keeps its age.
    @Test func owedNewerCopyOnAConfirmedDiskIsOrangeNotRed() async throws {
        let fixture = try ModelFixture(disks: FakeDisks(.notConnected))
        var hdd = try fixture.disk("HDD", every: 14)
        hdd.disk = mine
        let source = try fixture.folderSource("S1", to: [hdd], schedule: .weekly)
        let copiedAt = Date().addingTimeInterval(-5 * 86400)
        var state = try legacyState([source], at: hdd, copiedAt: copiedAt, store: fixture.store)
        let missedAt = Date().addingTimeInterval(-2 * 86400)
        state.updateSource(source.id) { $0.lastRun = missedAt }
        state.debts = [Debt(sourceId: source.id, destinationId: hdd.id, since: missedAt, elsewhere: false)]
        try await fixture.use(Config(sources: [source], destinations: [hdd]), state: state)
        let model = fixture.model

        #expect(model.state.deliveredCopyDate(sourceId: source.id, destinationId: hdd.id).map { abs($0.timeIntervalSince(copiedAt)) < 1 } == true)
        let status = model.snapshot.status(of: source, lastBackup: copiedAt)
        #expect(status.severity == .attention)
        if case .overdue = status { Issue.record("a debt is not a lost copy") }
        #expect(model.snapshot.delivery(of: source, to: hdd) == .waiting)
        #expect(model.snapshot.overall == .attention)
    }
}
