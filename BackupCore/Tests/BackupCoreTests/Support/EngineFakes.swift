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
    var owners: [String: UUID] = [:]
    var writeError: Error?
    var deleteError: Error?
    var undeletable: Set<String> = []
    var listError: Error?
    var removeIncompleteError: Error?
    var materialized: URL?
    private(set) var log: [String] = []
    private(set) var reusedStoredFiles: [Bool] = []
    private(set) var writtenManifests: [SnapshotManifest] = []
    private(set) var writtenPayloads: [Payload] = []

    func isAvailable() async -> Bool { available }

    func listSnapshots(sourceSlug: String) async throws -> [Snapshot] {
        if let listError { throw listError }
        return snapshots
    }

    func owners(sourceSlug: String) async throws -> [String: UUID] {
        owners
    }

    func removeIncomplete(sourceSlug: String) async throws {
        if let removeIncompleteError { throw removeIncompleteError }
        log.append("removeIncomplete")
    }

    func write(_ payload: Payload, manifest: SnapshotManifest, sourceSlug: String, snapshotName: String, reusingStoredFiles: Bool) async throws {
        if let writeError { throw writeError }
        log.append("write:\(snapshotName)")
        reusedStoredFiles.append(reusingStoredFiles)
        writtenManifests.append(manifest)
        writtenPayloads.append(payload)
        snapshots.append(Snapshot(name: snapshotName, date: manifest.collectedAt))
        owners[snapshotName] = manifest.sourceId
    }

    func usedBytes() async throws -> Int64 { 0 }

    func canShareUnchangedFiles() async -> Bool? { true }

    func materialize(_ snapshot: Snapshot, sourceSlug: String, scratch: URL) async throws -> URL {
        guard let materialized else { throw DestinationError.unavailable }
        log.append("materialize:\(snapshot.name)")
        return materialized
    }

    func delete(_ snapshot: Snapshot, sourceSlug: String) async throws {
        if let deleteError { throw deleteError }
        if undeletable.contains(snapshot.name) { throw POSIXError(.EPERM) }
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
