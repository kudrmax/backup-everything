import AppKit
import BackupCore
import Foundation
import Observation
import SwiftUI

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
    private var latestReport = StatusReport(items: [])
    private(set) var runs: [RunRecord] = []
    private(set) var templates: [SourceTemplate] = []
    private(set) var activeOperations = 0
    private(set) var problem: String?
    private(set) var activity = ActivityTracker()
    private(set) var unavailableDestinations: Set<UUID> = []
    /// How much space the copies take in each destination; measured in the background while no backups run.
    /// For a disconnected disk, the size from the last time it was connected.
    private(set) var destinationUsage: [UUID: Int64] = AppModel.rememberedUsage()
    /// Whether copies in each destination can share unchanged files, as of the last time it was connected.
    private(set) var destinationSharing: [UUID: Bool] = AppModel.rememberedSharing()
    private(set) var waitingPackages: [UUID: Int64] = [:]
    private(set) var freeSpace: Int64?
    @ObservationIgnored private var lastSpaceCheck = Date.distantPast
    @ObservationIgnored private var lastConnected: Set<UUID> = []

    private enum ActivityEvent {
        case progress(RunProgress)
        case settled
    }

    @ObservationIgnored var onNotices: ([Notice]) -> Void = { _ in }
    @ObservationIgnored var onChange: () -> Void = {}
    /// Settings were saved: new destinations and sources should get a copy right away, not at the next due time.
    @ObservationIgnored var onConfigEdited: () -> Void = {}

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let icons: IconStore
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
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
        icons = IconStore(directory: store.iconsDirectory)
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
    var report: StatusReport { LiveReport.of(latestReport, running: activity.active) }
    var headline: String { Texts.headline(report, isWorking: isWorking) }
    var headlineSymbol: String { isBusyWithoutProblems ? "arrow.triangle.2.circlepath.circle.fill" : StatusStyle.symbol(report.overall) }
    var headlineColor: Color { isBusyWithoutProblems ? .blue : StatusStyle.color(report.overall) }
    private var isBusyWithoutProblems: Bool { isWorking && report.items.isEmpty }
    var isFirstLaunch: Bool { config.destinations.isEmpty }
    var isRcloneInstalled: Bool { rclone.find() != nil }

    func prepare() {
        do {
            try Bootstrap(store: store, workDirectory: workDirectory).prepare(now: Date())
            config = try store.loadConfig()
            state = try store.loadState()
            templates = store.loadTemplates()
            dropUnusedIcons()
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

    func cancelWaiting(_ source: Source) async {
        await perform { try await self.coordinator.cancelWaiting(sourceId: source.id) }
    }

    /// The run was started by the button and is waiting for a person: only such a wait can be cancelled.
    func isWaitingForPerson(_ source: Source) -> Bool {
        let sourceState = state.sourceState(source.id)
        guard let chain = sourceState.chain else {
            return sourceState.armedAt != nil && !(nextDue(of: source).map { $0 <= Date() } ?? false)
        }
        guard chain.startedBy == .button, chain.failure == nil, chain.stepIndex < source.steps.count else { return false }
        return source.steps[chain.stepIndex].needsHuman
    }

    func restartChain(_ source: Source) async {
        await perform { try await self.coordinator.restartChain(sourceId: source.id) }
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
            latestReport = try await coordinator.statusReport()
            problem = nil
            refreshAvailability()
            refreshSpace()
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
            return editor.makeSource(name: "", steps: [.folder("")], now: Date(), in: config)
        }
        return editor.makeSource(
            name: template.name,
            steps: template.steps.map { SourceStep(name: $0.name, kind: $0.kind) },
            schedule: template.schedule,
            retention: template.retention,
            description: template.description,
            instructions: template.instructions,
            now: Date(),
            in: config
        )
    }

    func save(_ source: Source) async {
        await edit { self.editor.save(source, in: &$0) }
        dropUnusedIcons()
    }

    func delete(_ source: Source) async {
        await edit { self.editor.removeSource(source.id, from: &$0) }
        dropUnusedIcons()
    }

    func orderSources(_ ids: [UUID]) async {
        await edit { self.editor.orderSources(ids, in: &$0) }
    }

    func importIcon(from file: URL) -> String? {
        guard let png = IconImporter.pngData(from: file) else {
            problem = "Could not read the image “\(file.lastPathComponent)”."
            return nil
        }
        do {
            return try icons.add(png)
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }

    func iconImage(_ name: String?) -> NSImage? {
        guard let name else { return nil }
        if let cached = iconCache[name] { return cached }
        let image = NSImage(contentsOf: icons.url(for: name))
        iconCache[name] = image
        return image
    }

    private func dropUnusedIcons() {
        icons.removeUnused(keeping: Set(config.sources.compactMap(\.icon)))
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
        SourceStatus.of(source, report: report, lastRun: lastBackup(of: source))
    }

    func lastBackup(of source: Source) -> Date? {
        let sourceState = state.sourceState(source.id)
        return sourceState.lastSuccess ?? sourceState.lastRun
    }

    func nextDue(of source: Source) -> Date? {
        let sourceState = state.sourceState(source.id)
        guard let due = planner.dueDate(for: source, state: sourceState) else { return nil }
        return max(due, sourceState.retryAfter ?? due)
    }

    func chain(of sourceId: UUID) -> ChainState? {
        state.sourceState(sourceId).chain
    }

    func stage(of source: Source) -> SourceStage? {
        activity.stage(of: source.id)
    }

    func runStatus(of source: Source) -> String? {
        activity.status(of: source.id)
    }

    func runStep(of source: Source) -> (index: Int, count: Int)? {
        activity.step(of: source.id)
    }

    func runStartedAt(of source: Source) -> Date? {
        activity.startedAt(of: source.id)
    }

    func usualDuration(of source: Source) -> TimeInterval? {
        RunTiming.usualDuration(of: source.id, in: runs, copying: activity.isCopying(source.id))
    }

    var currentSourceName: String? {
        activity.current.flatMap(config.source)?.name
    }

    var runningSource: Source? {
        activity.current.flatMap(config.source)
    }

    var menuLines: [MenuLine] {
        MenuLines.of(config: config, state: state, report: report, unavailable: unavailableDestinations)
    }

    var latestBackup: Date? {
        config.sources.compactMap(lastBackup(of:)).max()
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

    /// The missed backup exists on another disk of the source.
    func isCoveredElsewhere(_ source: Source, for destination: Destination) -> Bool {
        state.debts.first { $0.sourceId == source.id && $0.destinationId == destination.id }?.elsewhere ?? true
    }

    /// Other disks of the source that hold its copy.
    func otherCopies(of source: Source, besides destination: Destination) -> [Destination] {
        config.destinations(of: source).filter { other in
            other.id != destination.id && state.lastDeliveredSnapshot(sourceId: source.id, destinationId: other.id) != nil
        }
    }

    /// When a “from time to time” disk will be asked to connect; `nil` means nothing is owed to it.
    func connectDeadline(of destination: Destination) -> Date? {
        planner.connectDeadline(for: destination, state: state)
    }

    func waitingSources(for destination: Destination) -> [Source] {
        state.debts(forDestination: destination.id).compactMap { config.source($0.sourceId) }
    }

    func condition(of destination: Destination) -> DestinationCondition {
        DestinationCondition.of(destination.id, report: report, unavailable: unavailableDestinations)
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

    func reveal(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            problem = "Not found: \(url.path). The disk may not be connected."
            return
        }
        if isDirectory.boolValue {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
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
        lastSpaceCheck = .distantPast
        await refresh()
        activityFeed.yield(.settled)
        onChange()
    }

    var workingSpace: WorkingSpace.Need {
        var lastSizes: [UUID: Int64] = [:]
        for run in runs where run.collectError == nil && lastSizes[run.sourceId] == nil {
            if let bytes = run.totalBytes { lastSizes[run.sourceId] = bytes }
        }
        return WorkingSpace.need(sources: config.sources, lastSizes: lastSizes, waiting: waitingPackages)
    }

    /// Walks the destination folders, so only between backups and, if nothing changed, at most once a minute.
    /// Right away when a disk is connected and when a backup finishes.
    private func refreshSpace(force: Bool = false) {
        guard activeOperations == 0, force || Date().timeIntervalSince(lastSpaceCheck) > 60 else { return }
        lastSpaceCheck = Date()
        let destinations = config.destinations
        let stores = stores
        let pending = CoreAssembly.pendingDirectory(in: workDirectory)
        let work = workDirectory
        Task {
            var usage = destinationUsage.filter { id, _ in destinations.contains { $0.id == id } }
            var sharing = destinationSharing.filter { id, _ in destinations.contains { $0.id == id } }
            for destination in destinations {
                let store = stores.store(for: destination)
                if let canShare = await store.canShareUnchangedFiles() { sharing[destination.id] = canShare }
                guard await store.isAvailable(), let bytes = try? await store.usedBytes() else { continue }
                usage[destination.id] = bytes
            }
            destinationSharing = sharing
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: sharing.map { ($0.key.uuidString, $0.value) }), forKey: Self.sharingKey)
            let measured = await Task.detached { () -> ([UUID: Int64], Int64?) in
                var waiting: [UUID: Int64] = [:]
                let names = (try? FileManager.default.contentsOfDirectory(atPath: pending.path)) ?? []
                for name in names {
                    guard let id = UUID(uuidString: name) else { continue }
                    waiting[id] = Self.size(of: pending.appendingPathComponent(name))
                }
                let free = (try? work.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
                return (waiting, free)
            }.value
            destinationUsage = usage
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: usage.map { ($0.key.uuidString, $0.value) }), forKey: Self.usageKey)
            waitingPackages = measured.0
            freeSpace = measured.1
        }
    }

    private static let usageKey = "destinationUsage"
    private static let sharingKey = "destinationSharing"

    private static func rememberedSharing() -> [UUID: Bool] {
        let stored = UserDefaults.standard.dictionary(forKey: sharingKey) as? [String: Bool] ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    private static func rememberedUsage() -> [UUID: Int64] {
        let stored = UserDefaults.standard.dictionary(forKey: usageKey) as? [String: Int64] ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    private nonisolated static func size(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private func refreshAvailability() {
        let destinations = config.destinations
        Task {
            var unavailable: Set<UUID> = []
            for destination in destinations where !(await isAvailable(destination)) {
                unavailable.insert(destination.id)
            }
            let connected = Set(destinations.map(\.id)).subtracting(unavailable)
            let justConnected = !connected.subtracting(lastConnected).isEmpty
            lastConnected = connected
            unavailableDestinations = unavailable
            if justConnected { refreshSpace(force: true) }
        }
    }

    private func handle(_ event: ActivityEvent) {
        switch event {
        case let .progress(.canUnplug(sourceId, sourceName)):
            onNotices([.deviceCanBeUnplugged(sourceId: sourceId, sourceName: sourceName)])
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
        onConfigEdited()
    }
}
