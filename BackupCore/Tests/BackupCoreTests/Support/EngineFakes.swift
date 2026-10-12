import Foundation
@testable import BackupCore

final class FakeSourceProvider: SourceProvider, @unchecked Sendable {
    var result: Result<Payload, Error>
    private(set) var collectCount = 0
    private(set) var finished: [PayloadDelivery] = []
    var finishError: Error?

    init(result: Result<Payload, Error>) {
        self.result = result
    }

    var statuses: [String] = []

    func collect(at date: Date, status: @escaping StatusHandler) async throws -> Payload {
        collectCount += 1
        statuses.forEach(status)
        return try result.get()
    }

    func finish(_ payload: Payload, delivered: PayloadDelivery) throws {
        finished.append(delivered)
        if let finishError { throw finishError }
    }
}

final class FakeDestinationStore: DestinationStore, @unchecked Sendable {
    var readinessValue: DestinationReadiness = .ready
    var snapshots: [Snapshot] = []
    var writeError: Error?
    var listError: Error?
    private(set) var log: [String] = []
    private(set) var writtenPayloads: [Payload] = []

    func readiness() async -> DestinationReadiness { readinessValue }

    func copies(of slug: String) async throws -> [Snapshot] {
        if let listError { throw listError }
        return snapshots.sorted { $0.date < $1.date }
    }

    func unfinishedCopies(of slug: String) async throws -> [Snapshot] { [] }

    func write(_ payload: Payload, sourceSlug: String, snapshotName: String) async throws {
        if let writeError { throw writeError }
        log.append("write:\(snapshotName)")
        writtenPayloads.append(payload)
        snapshots.append(Snapshot(name: snapshotName, date: Fixtures.naming.date(from: snapshotName) ?? payload.collectedAt))
    }

    func usedBytes() async throws -> Int64 { 0 }

    func url(of snapshot: Snapshot, sourceSlug: String) throws -> URL {
        URL(fileURLWithPath: "/fake/\(sourceSlug)/\(snapshot.name)", isDirectory: true)
    }
}

struct FakeFactories: SourceProviderFactory, DestinationStoreFactory {
    let sourceProvider: FakeSourceProvider
    let destinationStores: [UUID: FakeDestinationStore]

    func provider(for source: Source) -> any SourceProvider { sourceProvider }

    func store(for destination: Destination) -> any DestinationStore { destinationStores[destination.id]! }
}
