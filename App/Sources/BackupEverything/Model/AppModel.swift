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
    private(set) var destinationUsage: [UUID: Int64]
    /// Whether copies in each destination can share unchanged files, as of the last time it was connected.
    private(set) var destinationSharing: [UUID: Bool]
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
    @ObservationIgnored private let runner: any ProcessRunner
    @ObservationIgnored private let rclone: RcloneLocator
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let finder: any FileRevealing
    @ObservationIgnored private let trash: ManualExportInbox.Trash
    @ObservationIgnored private let editor = ConfigEditor()
    @ObservationIgnored private let planner: SchedulePlanner
    @ObservationIgnored private let retention = RetentionPolicy()
    @ObservationIgnored private let activityEvents: AsyncStream<ActivityEvent>
    @ObservationIgnored private let activityFeed: AsyncStream<ActivityEvent>.Continuation

    init(
        dataDirectory: URL,
        workDirectory: URL,
        runner: any ProcessRunner = SystemProcessRunner(),
        rclone: RcloneLocator = RcloneLocator(),
        defaults: UserDefaults = .standard,
        finder: any FileRevealing = WorkspaceFinder(),
        trash: @escaping ManualExportInbox.Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        store = Store(dataDirectory: dataDirectory)
        self.runner = runner
        self.rclone = rclone
        self.defaults = defaults
        self.finder = finder
        self.trash = trash
        destinationUsage = Self.rememberedUsage(in: defaults)
        destinationSharing = Self.rememberedSharing(in: defaults)
        icons = IconStore(directory: store.iconsDirectory)
        self.workDirectory = workDirectory
        let (events, feed) = AsyncStream.makeStream(of: ActivityEvent.self)
        activityEvents = events
        activityFeed = feed
        coordinator = CoreAssembly.makeCoordinator(
            dataDirectory: dataDirectory,
            workDirectory: workDirectory,
            runner: runner,
            rclone: rclone,
            trash: trash,
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
            try Bootstrap(store: store, workDirectory: workDirectory, trash: trash).prepare(now: Date())
            config = try store.loadConfig()
            state = try store.loadState()
            templates = store.loadTemplates()
            dropUnusedIcons(in: config)
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

    /// The source as written to the settings, or nil if they could not be written.
    @discardableResult
    func save(_ source: Source) async -> Source? {
        let saved = await edit { self.editor.save(source, in: &$0) }
        saved.map(dropUnusedIcons(in:))
        return saved?.source(source.id)
    }

    @discardableResult
    func delete(_ source: Source) async -> Bool {
        let saved = await edit { self.editor.removeSource(source.id, from: &$0) }
        saved.map(dropUnusedIcons(in:))
        return saved != nil
    }

    func orderSources(_ ids: [UUID]) async {
        _ = await edit { self.editor.orderSources(ids, in: &$0) }
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

    private func dropUnusedIcons(in saved: Config) {
        icons.removeUnused(keeping: Set(saved.sources.compactMap(\.icon)))
    }

    /// The destination as written to the settings, or nil if they could not be written.
    @discardableResult
    func save(_ destination: Destination) async -> Destination? {
        await edit { self.editor.save(destination, in: &$0) }?.destination(destination.id)
    }

    @discardableResult
    func delete(_ destination: Destination) async -> Bool {
        await edit { self.editor.removeDestination(destination.id, from: &$0) } != nil
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

    /// When the newest copy delivered to at least one destination was collected.
    /// Settings from before `lastSuccess` was kept fall back to the history.
    func lastBackup(of source: Source) -> Date? {
        state.sourceState(source.id).lastSuccess ?? runs
            .filter { $0.sourceId == source.id && $0.deliveries.contains(where: \.outcome.isDelivered) }
            .map { $0.collectedAt ?? $0.startedAt }
            .max()
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

    private var activeState: AppState {
        state.pausingDisabledSources(of: config)
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
        planner.connectDeadline(for: destination, state: activeState)
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
        let snapshots = (try? await stores.store(for: destination).copies(of: source)) ?? []
        return snapshots.sorted { $0.date > $1.date }
    }

    func sources(backingUpTo destination: Destination) -> [Source] {
        config.sources.filter { $0.destinationIds.contains(destination.id) }
    }

    /// Copies of each source in the destination, newest first; `nil` when the destination can’t be reached.
    func copies(in destination: Destination) async -> [UUID: [Snapshot]]? {
        guard await isAvailable(destination) else { return nil }
        var loaded: [UUID: [Snapshot]] = [:]
        for source in sources(backingUpTo: destination) {
            loaded[source.id] = await snapshots(of: source, in: destination)
        }
        return loaded
    }

    /// The rules come from the edited source, the folder of its copies from the saved one.
    func retentionPreview(for edited: Source) async -> [RetentionPreview] {
        var source = edited
        source.slug = config.source(edited.id)?.slug ?? edited.slug
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
            finder.open(url)
        } else {
            finder.select(url)
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
            defaults.set(Dictionary(uniqueKeysWithValues: sharing.map { ($0.key.uuidString, $0.value) }), forKey: Self.sharingKey)
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
            defaults.set(Dictionary(uniqueKeysWithValues: usage.map { ($0.key.uuidString, $0.value) }), forKey: Self.usageKey)
            waitingPackages = measured.0
            freeSpace = measured.1
        }
    }

    private static let usageKey = "destinationUsage"
    private static let sharingKey = "destinationSharing"

    private static func rememberedSharing(in defaults: UserDefaults) -> [UUID: Bool] {
        let stored = defaults.dictionary(forKey: sharingKey) as? [String: Bool] ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    private static func rememberedUsage(in defaults: UserDefaults) -> [UUID: Int64] {
        let stored = defaults.dictionary(forKey: usageKey) as? [String: Int64] ?? [:]
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

    /// The settings as written, or nil if they could not be read or written.
    private func edit(_ change: (inout Config) -> Void) async -> Config? {
        var written: Config?
        var failure: String?
        do {
            var updated = try store.loadConfig()
            change(&updated)
            try store.saveConfig(updated)
            written = try store.loadConfig()
        } catch {
            failure = error.localizedDescription
        }
        await refresh()
        if let failure { problem = failure }
        onChange()
        onConfigEdited()
        return written
    }
}
