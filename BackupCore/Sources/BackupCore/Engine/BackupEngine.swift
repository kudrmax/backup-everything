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
            let entries = try walker.entries(of: payload)
            try SnapshotManifest.checkTopLevelNames(of: entries)
            stats = walker.stats(of: entries)
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

    /// Catch-up with an existing copy: the same snapshot under the same name is transferred from `origin` to `destinations`, the source is not gathered again.
    public func copy(_ snapshot: Snapshot, of source: Source, from origin: Destination, to destinations: [Destination]) async -> RunRecord {
        var record = RunRecord(
            sourceId: source.id,
            sourceName: source.name,
            trigger: .catchUp,
            startedAt: time.now,
            finishedAt: time.now
        )
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("copy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            let folder = try await stores.store(for: origin).materialize(snapshot, sourceSlug: source.slug, scratch: scratch)
            let payload = Payload(root: folder, excludedAtTop: SnapshotManifest.serviceFileNames, collectedAt: snapshot.date)
            let stats = walker.stats(of: try walker.entries(of: payload))
            let manifest = SnapshotManifest(
                sourceId: source.id,
                sourceName: source.name,
                collectedAt: snapshot.date,
                fileCount: stats.fileCount,
                totalBytes: stats.totalBytes
            )
            record.snapshotName = snapshot.name
            record.collectedAt = snapshot.date
            record.fileCount = stats.fileCount
            record.totalBytes = stats.totalBytes
            record.details = "Copied from “\(origin.name)”"
            record.copiedFrom = origin.name
            for destination in destinations {
                let store = stores.store(for: destination)
                let outcome: DeliveryOutcome
                if await store.isAvailable() {
                    progress(.delivering(sourceId: source.id, destinationId: destination.id))
                    outcome = await deliver(payload, manifest: manifest, snapshotName: snapshot.name, source: source, to: store)
                } else {
                    outcome = .unavailable
                }
                record.deliveries.append(Delivery(destinationId: destination.id, destinationName: destination.name, outcome: outcome))
            }
        } catch {
            let message = "Could not take the copy from “\(origin.name)”: \(error.localizedDescription)"
            record.deliveries = destinations.map { Delivery(destinationId: $0.id, destinationName: $0.name, outcome: .failed(message: message)) }
        }
        record.finishedAt = time.now
        progress(.finished(sourceId: source.id))
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
            let existing = try await store.copies(of: source)
            if !existing.contains(where: { $0.name == snapshotName }) {
                try await store.write(
                    payload,
                    manifest: manifest,
                    sourceSlug: source.slug,
                    snapshotName: snapshotName,
                    reusingStoredFiles: source.savesSpace
                )
            }
        } catch {
            return .failed(message: error.localizedDescription)
        }
        let doomed: [Snapshot]
        do {
            try await store.removeIncomplete(sourceSlug: source.slug)
            let snapshots = try await store.copies(of: source)
            doomed = retention.snapshotsToDelete(snapshots, rules: source.retention).filter { $0.name != snapshotName }
        } catch {
            return .delivered(pruned: 0, warning: cleanupWarning([error.localizedDescription]))
        }
        var pruned = 0
        var problems: [String] = []
        for snapshot in doomed {
            do {
                try await store.delete(snapshot, sourceSlug: source.slug)
                pruned += 1
            } catch {
                if !problems.contains(error.localizedDescription) { problems.append(error.localizedDescription) }
            }
        }
        return .delivered(pruned: pruned, warning: problems.isEmpty ? nil : cleanupWarning(problems))
    }

    private func cleanupWarning(_ problems: [String]) -> String {
        "Could not clean up old copies: \(problems.joined(separator: " "))"
    }
}
