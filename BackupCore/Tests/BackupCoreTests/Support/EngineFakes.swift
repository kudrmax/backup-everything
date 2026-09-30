import Foundation
@testable import BackupCore

final class FakeSourceProvider: SourceProvider, @unchecked Sendable {
    var result: Result<Payload, Error>
    private(set) var collectCount = 0
    private(set) var finished: [Bool] = []

    init(result: Result<Payload, Error>) {
        self.result = result
    }

    var statuses: [String] = []

    func collect(at date: Date, status: @escaping StatusHandler) async throws -> Payload {
        collectCount += 1
        statuses.forEach(status)
        return try result.get()
    }

    func finish(_ payload: Payload, deliveredEverywhere: Bool) {
        finished.append(deliveredEverywhere)
    }
}

final class FakeDestinationStore: DestinationStore, @unchecked Sendable {
    var available = true
    var snapshots: [Snapshot] = []
    var writeError: Error?
    var deleteError: Error?
    private(set) var log: [String] = []

    func isAvailable() async -> Bool { available }

    func listSnapshots(sourceSlug: String) async throws -> [Snapshot] { snapshots }

    func removeIncomplete(sourceSlug: String) async throws {
        log.append("removeIncomplete")
    }

    func write(_ payload: Payload, manifest: SnapshotManifest, sourceSlug: String, snapshotName: String) async throws {
        if let writeError { throw writeError }
        log.append("write:\(snapshotName)")
        snapshots.append(Snapshot(name: snapshotName, date: manifest.collectedAt))
    }

    func usedBytes() async throws -> Int64 { 0 }

    func delete(_ snapshot: Snapshot, sourceSlug: String) async throws {
        if let deleteError { throw deleteError }
        log.append("delete:\(snapshot.name)")
        snapshots.removeAll { $0 == snapshot }
    }
}

struct FakeFactories: SourceProviderFactory, DestinationStoreFactory {
    let sourceProvider: FakeSourceProvider
    let destinationStores: [UUID: FakeDestinationStore]

    func provider(for source: Source) -> any SourceProvider { sourceProvider }

    func store(for destination: Destination) -> any DestinationStore { destinationStores[destination.id]! }
}
