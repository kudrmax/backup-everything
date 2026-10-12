import Foundation

public struct BackupEngine: Sendable {
    private let providers: any SourceProviderFactory
    private let stores: any DestinationStoreFactory
    private let naming: SnapshotNaming
    private let time: any TimeSource
    private let progress: ProgressHandler
    private let walker = PayloadWalker()

    public init(
        providers: any SourceProviderFactory,
        stores: any DestinationStoreFactory,
        naming: SnapshotNaming,
        time: any TimeSource,
        progress: @escaping ProgressHandler = { _ in }
    ) {
        self.providers = providers
        self.stores = stores
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
        var record = RunRecord(sourceId: source.id, sourceName: source.name, trigger: trigger, startedAt: time.now, finishedAt: time.now)
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
        let stats: PayloadStats
        do {
            let entries = try walker.entries(of: payload)
            try CopyFolder.checkTopLevelNames(of: entries)
            stats = walker.stats(of: entries)
            guard stats.fileCount > 0 else { throw SourceError.emptyResult }
        } catch {
            record.collectError = error.localizedDescription
            if let problem = release(payload, of: provider, delivered: .nowhere) {
                record.collectError = "\(error.localizedDescription) \(problem)"
            }
            record.finishedAt = time.now
            return record
        }

        let snapshotName = naming.name(for: record.startedAt)
        record.snapshotName = snapshotName
        record.collectedAt = payload.collectedAt
        record.fileCount = stats.fileCount
        record.totalBytes = stats.totalBytes
        record.details = payload.details
        record.deliversAnOlderCopy = payload.madeEarlier

        for destination in destinations {
            let outcome: DeliveryOutcome
            if let store = reachable[destination.id] {
                progress(.delivering(sourceId: source.id, destinationId: destination.id))
                outcome = await deliver(payload, snapshotName: snapshotName, slug: source.slug, to: store)
            } else {
                outcome = .unavailable
            }
            record.deliveries.append(Delivery(destinationId: destination.id, destinationName: destination.name, outcome: outcome))
        }
        if let problem = release(payload, of: provider, delivered: record.payloadDelivery) {
            record.deliveries = record.deliveries.map { delivery in
                var delivery = delivery
                delivery.outcome = delivery.outcome.adding(problem)
                return delivery
            }
        }
        record.finishedAt = time.now
        return record
    }

    /// A copy at least as new as the collected data (the same package delivered earlier) counts as delivered.
    private func deliver(_ payload: Payload, snapshotName: String, slug: String, to store: any DestinationStore) async -> DeliveryOutcome {
        do {
            guard try await !store.copies(of: slug).contains(where: { $0.date >= payload.collectedAt }) else {
                return .delivered(pruned: 0, warning: nil)
            }
            let warning = try await store.write(payload, sourceSlug: slug, snapshotName: snapshotName)
            return .delivered(pruned: 0, warning: warning)
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    private func release(_ payload: Payload, of provider: any SourceProvider, delivered: PayloadDelivery) -> String? {
        do {
            try provider.finish(payload, delivered: delivered)
            return nil
        } catch {
            return "Could not clear the work folder: \(error.localizedDescription)"
        }
    }
}

private extension RunRecord {
    var payloadDelivery: PayloadDelivery {
        if deliveries.allSatisfy(\.outcome.isDelivered) { return .everywhere }
        return deliveries.contains(where: \.outcome.isDelivered) ? .partly : .nowhere
    }
}
