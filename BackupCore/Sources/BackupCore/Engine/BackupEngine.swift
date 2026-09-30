import Foundation

public struct BackupEngine: Sendable {
    private let providers: any SourceProviderFactory
    private let stores: any DestinationStoreFactory
    private let retention: RetentionPolicy
    private let naming: SnapshotNaming
    private let time: any TimeSource
    private let progress: ProgressHandler
    private let walker = PayloadWalker()

    public init(
        providers: any SourceProviderFactory,
        stores: any DestinationStoreFactory,
        retention: RetentionPolicy,
        naming: SnapshotNaming,
        time: any TimeSource,
        progress: @escaping ProgressHandler = { _ in }
    ) {
        self.providers = providers
        self.stores = stores
        self.retention = retention
        self.naming = naming
        self.time = time
        self.progress = progress
    }

    public func run(source: Source, destinations: [Destination], trigger: RunTrigger) async -> RunRecord {
        let record = await perform(source: source, destinations: destinations, trigger: trigger)
        progress(.finished(sourceId: source.id))
        return record
    }

    private func perform(source: Source, destinations: [Destination], trigger: RunTrigger) async -> RunRecord {
        var record = RunRecord(
            sourceId: source.id,
            sourceName: source.name,
            trigger: trigger,
            startedAt: time.now,
            finishedAt: time.now
        )
        var reachable: [UUID: any DestinationStore] = [:]
        for destination in destinations {
            let store = stores.store(for: destination)
            if await store.isAvailable() { reachable[destination.id] = store }
        }
        guard !reachable.isEmpty else {
            record.deliveries = destinations.map { Delivery(destinationId: $0.id, destinationName: $0.name, outcome: .unavailable) }
            record.finishedAt = time.now
            return record
        }

        let provider = providers.provider(for: source)
        let payload: Payload
        let stats: PayloadStats
        progress(.collecting(sourceId: source.id))
        do {
            payload = try await provider.collect(at: record.startedAt) { [progress] text in
                progress(.status(sourceId: source.id, text: text))
            }
        } catch {
            record.collectError = error.localizedDescription
            record.finishedAt = time.now
            return record
        }
        do {
            stats = walker.stats(of: try walker.entries(of: payload))
            guard stats.fileCount > 0 else { throw SourceError.emptyResult }
        } catch {
            provider.finish(payload, deliveredEverywhere: false)
            record.collectError = error.localizedDescription
            record.finishedAt = time.now
            return record
        }

        let snapshotName = naming.name(for: payload.collectedAt)
        let manifest = SnapshotManifest(
            sourceId: source.id,
            sourceName: source.name,
            collectedAt: payload.collectedAt,
            fileCount: stats.fileCount,
            totalBytes: stats.totalBytes
        )
        record.snapshotName = snapshotName
        record.collectedAt = payload.collectedAt
        record.fileCount = stats.fileCount
        record.totalBytes = stats.totalBytes
        record.details = payload.details

        for destination in destinations {
            let outcome: DeliveryOutcome
            if let store = reachable[destination.id] {
                progress(.delivering(sourceId: source.id, destinationId: destination.id))
                outcome = await deliver(payload, manifest: manifest, snapshotName: snapshotName, source: source, to: store)
            } else {
                outcome = .unavailable
            }
            record.deliveries.append(Delivery(destinationId: destination.id, destinationName: destination.name, outcome: outcome))
        }
        provider.finish(payload, deliveredEverywhere: record.deliveries.allSatisfy(\.outcome.isDelivered))
        record.finishedAt = time.now
        return record
    }

    private func deliver(
        _ payload: Payload,
        manifest: SnapshotManifest,
        snapshotName: String,
        source: Source,
        to store: any DestinationStore
    ) async -> DeliveryOutcome {
        do {
            try await store.removeIncomplete(sourceSlug: source.slug)
            let existing = try await store.listSnapshots(sourceSlug: source.slug)
            if !existing.contains(where: { $0.name == snapshotName }) {
                try await store.write(payload, manifest: manifest, sourceSlug: source.slug, snapshotName: snapshotName)
            }
        } catch {
            return .failed(message: error.localizedDescription)
        }
        do {
            let snapshots = try await store.listSnapshots(sourceSlug: source.slug)
            let doomed = retention.snapshotsToDelete(snapshots, rules: source.retention).filter { $0.name != snapshotName }
            for snapshot in doomed {
                try await store.delete(snapshot, sourceSlug: source.slug)
            }
            return .delivered(pruned: doomed.count, warning: nil)
        } catch {
            return .delivered(pruned: 0, warning: "Не удалось очистить старые копии: \(error.localizedDescription)")
        }
    }
}
