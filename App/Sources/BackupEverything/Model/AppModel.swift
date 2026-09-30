import BackupCore
import Foundation
import Observation

struct RetentionPreview: Identifiable {
    let destination: Destination
    let kept: [Snapshot]
    let doomed: [Snapshot]

    var id: UUID { destination.id }
}

@MainActor
@Observable
final class AppModel {
    private(set) var config = Config()
    private(set) var state = AppState()
    private(set) var report = StatusReport(items: [])
    private(set) var runs: [RunRecord] = []
    private(set) var templates: [SourceTemplate] = []
    private(set) var activeOperations = 0
    private(set) var problem: String?
    private(set) var activity = ActivityTracker()

    private enum ActivityEvent {
        case progress(RunProgress)
        case settled
    }

    @ObservationIgnored var onNotices: ([Notice]) -> Void = { _ in }
    @ObservationIgnored var onChange: () -> Void = {}

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let workDirectory: URL
    @ObservationIgnored private let coordinator: BackupCoordinator
    @ObservationIgnored private let stores: DefaultDestinationStoreFactory
    @ObservationIgnored private let runner = SystemProcessRunner()
    @ObservationIgnored private let rclone = RcloneLocator()
    @ObservationIgnored private let editor = ConfigEditor()
    @ObservationIgnored private let planner: SchedulePlanner
    @ObservationIgnored private let retention = RetentionPolicy()
    @ObservationIgnored private let activityEvents: AsyncStream<ActivityEvent>
    @ObservationIgnored private let activityFeed: AsyncStream<ActivityEvent>.Continuation

    init(dataDirectory: URL, workDirectory: URL) {
        store = Store(dataDirectory: dataDirectory)
        self.workDirectory = workDirectory
        let (events, feed) = AsyncStream.makeStream(of: ActivityEvent.self)
        activityEvents = events
        activityFeed = feed
        coordinator = CoreAssembly.makeCoordinator(
            dataDirectory: dataDirectory,
            workDirectory: workDirectory,
            progress: { feed.yield(.progress($0)) }
        )
        stores = DefaultDestinationStoreFactory(runner: runner, rclone: rclone, naming: SnapshotNaming())
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        planner = SchedulePlanner(calendar: calendar)
    }

    var isWorking: Bool { activeOperations > 0 }
    var isFirstLaunch: Bool { config.destinations.isEmpty }
    var isRcloneInstalled: Bool { rclone.find() != nil }

    func prepare() {
        do {
            try Bootstrap(store: store, workDirectory: workDirectory).prepare(now: Date())
            config = try store.loadConfig()
            state = try store.loadState()
            templates = store.loadTemplates()
        } catch {
            problem = error.localizedDescription
        }
        Task { [weak self, activityEvents] in
            for await event in activityEvents {
                self?.handle(event)
            }
        }
    }

    func tick() async {
        await perform { try await self.coordinator.tick() }
    }

    func runNow(_ source: Source) async {
        await perform { try await self.coordinator.runNow(sourceId: source.id) }
    }

    func runAll() async {
        await perform { try await self.coordinator.runAllNow() }
    }

    func confirmPickup(_ source: Source) async {
        await perform { try await self.coordinator.confirmPickup(sourceId: source.id) }
    }

    func nextWake() async -> Date? {
        try? await coordinator.nextWake()
    }

    func refresh() async {
        do {
            config = try store.loadConfig()
            state = try store.loadState()
            runs = store.loadRuns(limit: 300)
            templates = store.loadTemplates()
            report = try await coordinator.statusReport()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    func dismissProblem() {
        problem = nil
    }

    // MARK: Editing

    func newSource(from template: SourceTemplate?) -> Source {
        guard let template else {
            return editor.makeSource(name: "Новый источник", kind: .folder(path: "", excludes: []), now: Date(), in: config)
        }
        return editor.makeSource(
            name: template.name,
            kind: template.kind,
            schedule: template.schedule,
            retention: template.retention,
            instructions: template.instructions,
            now: Date(),
            in: config
        )
    }

    func save(_ source: Source) async {
        await edit { self.editor.save(source, in: &$0) }
    }

    func delete(_ source: Source) async {
        await edit { self.editor.removeSource(source.id, from: &$0) }
    }

    func save(_ destination: Destination) async {
        await edit { self.editor.save(destination, in: &$0) }
    }

    func delete(_ destination: Destination) async {
        await edit { self.editor.removeDestination(destination.id, from: &$0) }
    }

    func maskConflicts(for source: Source) -> [Source] {
        var candidate = config
        editor.save(source, in: &candidate)
        return editor.maskConflicts(for: source, in: candidate)
    }

    // MARK: Queries

    func status(of source: Source) -> SourceStatus {
        SourceStatus.of(source, report: report, lastRun: state.sourceState(source.id).lastRun)
    }

    func lastRun(of source: Source) -> Date? {
        state.sourceState(source.id).lastRun
    }

    func nextDue(of source: Source) -> Date? {
        let sourceState = state.sourceState(source.id)
        guard let due = planner.dueDate(for: source, state: sourceState) else { return nil }
        return max(due, sourceState.retryAfter ?? due)
    }

    func stage(of source: Source) -> SourceStage? {
        activity.stage(of: source.id)
    }

    var currentSourceName: String? {
        activity.current.flatMap(config.source)?.name
    }

    func lastDelivery(of source: Source, to destination: Destination) -> (date: Date, outcome: DeliveryOutcome)? {
        for run in runs where run.sourceId == source.id {
            if let delivery = run.deliveries.first(where: { $0.destinationId == destination.id }) {
                return (run.finishedAt, delivery.outcome)
            }
        }
        return nil
    }

    func lastSize(of source: Source) -> Int64? {
        runs.first { $0.sourceId == source.id && $0.totalBytes != nil }?.totalBytes
    }

    func isWaiting(_ source: Source, for destination: Destination) -> Bool {
        state.debts.contains { $0.sourceId == source.id && $0.destinationId == destination.id }
    }

    func waitingSources(for destination: Destination) -> [Source] {
        state.debts(forDestination: destination.id).compactMap { config.source($0.sourceId) }
    }

    func lastCaughtUp(_ destination: Destination) -> Date? {
        state.destinationState(destination.id).lastCaughtUp
    }

    func isAvailable(_ destination: Destination) async -> Bool {
        await stores.store(for: destination).isAvailable()
    }

    func usedBytes(_ destination: Destination) async -> Int64? {
        try? await stores.store(for: destination).usedBytes()
    }

    func snapshots(of source: Source, in destination: Destination) async -> [Snapshot] {
        let snapshots = (try? await stores.store(for: destination).listSnapshots(sourceSlug: source.slug)) ?? []
        return snapshots.sorted { $0.date > $1.date }
    }

    func retentionPreview(for source: Source) async -> [RetentionPreview] {
        var previews: [RetentionPreview] = []
        for destination in source.destinationIds.compactMap(config.destination) {
            let all = await snapshots(of: source, in: destination)
            let kept = retention.snapshotsToKeep(all, rules: source.retention)
            previews.append(RetentionPreview(
                destination: destination,
                kept: all.filter(kept.contains),
                doomed: all.filter { !kept.contains($0) }
            ))
        }
        return previews
    }

    func localURL(of snapshot: Snapshot, source: Source, in destination: Destination) -> URL? {
        guard case let .localFolder(path) = destination.kind else { return nil }
        return AppPaths.expand(path).appendingPathComponent(source.slug).appendingPathComponent(snapshot.name)
    }

    func rcloneRemotes() async -> [String] {
        guard let executable = rclone.find(),
              let result = try? await runner.run(executable: executable, arguments: ["listremotes"], environment: [:], timeout: 15),
              result.exitCode == 0 else { return [] }
        return result.stdout.split(separator: "\n").map { $0.hasSuffix(":") ? String($0.dropLast()) : String($0) }
    }

    // MARK: Private

    private func perform(_ operation: @escaping @Sendable () async throws -> TickResult) async {
        activeOperations += 1
        do {
            let result = try await operation()
            onNotices(result.notices)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        activeOperations -= 1
        await refresh()
        activityFeed.yield(.settled)
        onChange()
    }

    private func handle(_ event: ActivityEvent) {
        switch event {
        case let .progress(progress):
            activity.apply(progress)
            if case .finished = progress {
                Task { await refresh() }
            }
        case .settled:
            if activeOperations == 0 { activity.reset() }
        }
    }

    private func edit(_ change: (inout Config) -> Void) async {
        do {
            var updated = try store.loadConfig()
            change(&updated)
            try store.saveConfig(updated)
        } catch {
            problem = error.localizedDescription
        }
        await refresh()
        onChange()
    }
}
