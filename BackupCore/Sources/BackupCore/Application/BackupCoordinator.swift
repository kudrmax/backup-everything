import Foundation

public struct CurrentStatus: Sendable, Equatable {
    public let config: Config
    public let state: AppState
    public let report: StatusReport
}

public actor BackupCoordinator {
    private let store: Store
    private let engine: BackupEngine
    private let inbox: ManualExportInbox
    private let chains: StepChainRunner
    private let stores: any DestinationStoreFactory
    private let time: any TimeSource
    private let quit: any QuitSignal
    private let progress: ProgressHandler
    private let planner: SchedulePlanner
    private let reporter: StatusReporter
    private let reminders = ReminderPlanner()
    private let reducer = StateReducer()
    private var queueTail: Task<Void, Never>?

    private enum ChainMode { case tick, runAll, runNow, confirm }

    public init(store: Store, engine: BackupEngine, inbox: ManualExportInbox, chains: StepChainRunner, stores: any DestinationStoreFactory,
                time: any TimeSource, calendar: Calendar, quit: any QuitSignal = ProcessGroups.shared, progress: @escaping ProgressHandler = { _ in }) {
        self.store = store
        self.engine = engine
        self.inbox = inbox
        self.chains = chains
        self.stores = stores
        self.time = time
        self.quit = quit
        self.progress = progress
        self.planner = SchedulePlanner(calendar: calendar)
        self.reporter = StatusReporter(planner: planner)
    }

    /// Sources the check will certainly run are marked “queued” right away, before their turn.
    public func tick() async throws -> TickResult {
        var announced: Set<UUID> = []
        if let config = try? store.loadConfig(), let state = try? loadState(for: config) {
            let foreseen = await foreseenWork(config: config, state: state, now: time.now)
            announce(foreseen)
            announced = Set(foreseen.map(\.id))
        }
        return try await enqueue { [announced] in try await self.performTick(announced: announced) }
    }

    public func runNow(sourceId: UUID) async throws -> TickResult {
        if let config = try? store.loadConfig(), let source = config.source(sourceId), !config.destinations(of: source).isEmpty, startsWithoutWaiting(source) {
            announce([source])
        }
        return try await enqueue { try await self.performRunNow(sourceId: sourceId) }
    }

    public func runAllNow() async throws -> TickResult {
        if let config = try? store.loadConfig() {
            announce(config.sources.filter { $0.enabled && !config.destinations(of: $0).isEmpty && startsWithoutWaiting($0) })
        }
        return try await enqueue { try await self.performRunAllNow() }
    }

    public func confirmPickup(sourceId: UUID) async throws -> TickResult { try await enqueue { try await self.performConfirmPickup(sourceId: sourceId) } }
    public func restartChain(sourceId: UUID) async throws -> TickResult { try await enqueue { try await self.performRestartChain(sourceId: sourceId) } }
    public func cancelWaiting(sourceId: UUID) async throws -> TickResult { try await enqueue { try await self.performCancelWaiting(sourceId: sourceId) } }

    public func statusReport() async throws -> StatusReport { try await currentStatus().report }

    /// The settings, the state with the copy cache refreshed from every reachable destination, and the status from both.
    /// Not queued behind backups: the refreshed cache is laid over the state as saved once the destinations are listed,
    /// so whatever a backup saved meanwhile stays.
    public func currentStatus() async throws -> CurrentStatus {
        let config = try store.loadConfig()
        var refreshed = try loadState(for: config)
        let unavailable = await refreshCache(config: config, state: &refreshed)
        var latest = try loadState(for: config)
        latest.copyCache.merge(refreshed.copyCache) { _, new in new }
        try store.saveState(latest)
        return CurrentStatus(config: config, state: latest, report: await report(config: config, state: latest, unavailable: unavailable, now: time.now))
    }

    public func nextWake() async throws -> Date? {
        let current = try await currentStatus()
        return planner.nextWake(config: current.config, state: current.state, now: time.now, needsAttention: current.report.overall != .ok)
    }

    /// The saved state without what the settings no longer know.
    private func loadState(for config: Config) throws -> AppState {
        var state = try store.loadState()
        reducer.dropOrphans(config: config, state: &state)
        return state
    }

    /// Lists the copies of every source on every reachable destination into the cache. Returns the unreachable destinations.
    private func refreshCache(config: Config, state: inout AppState) async -> Set<UUID> {
        var unavailable: Set<UUID> = []
        let now = time.now
        for destination in config.destinations {
            let store = stores.store(for: destination)
            guard await store.isAvailable() else {
                unavailable.insert(destination.id)
                continue
            }
            for source in config.sources where source.destinationIds.contains(destination.id) {
                guard let copies = try? await store.copies(of: source.slug) else { continue }
                state.recordCopies(sourceId: source.id, destinationId: destination.id, copies, seenAt: now)
            }
        }
        return unavailable
    }

    private func foreseenWork(config: Config, state: AppState, now: Date) async -> [Source] {
        var work: [Source] = []
        for source in config.sources where source.enabled {
            let targets = source.needsHuman
                ? await pendingTargets(of: source, config: config, state: state, now: now)
                : await targets(of: source, config: config, state: state, now: now)
            if !targets.isEmpty { work.append(source) }
        }
        return work
    }

    /// Reachable destinations that do not hold the package a source with a manual step keeps in pending until it is everywhere.
    private func pendingTargets(of source: Source, config: Config, state: AppState, now: Date) async -> [Destination] {
        guard planner.mayRetry(state.sourceState(source.id), now: now), let package = inbox.pendingPackage(for: source.id) else { return [] }
        let name = package.directory.lastPathComponent
        var reachable: [Destination] = []
        for destination in config.destinations(of: source) {
            let copies = state.cachedCopies(sourceId: source.id, destinationId: destination.id)?.copies ?? []
            guard !copies.contains(where: { $0.name == name }), await stores.store(for: destination).isAvailable() else { continue }
            reachable.append(destination)
        }
        return reachable
    }

    /// Reachable destinations of the source that need a copy now, by the copies actually there.
    private func targets(of source: Source, config: Config, state: AppState, now: Date) async -> [Destination] {
        guard planner.mayRetry(state.sourceState(source.id), now: now) else { return [] }
        let needing = planner.destinationsNeedingCopy(of: source, in: config, newest: { state.newestCopyDate(sourceId: source.id, destinationId: $0) }, now: now)
        var reachable: [Destination] = []
        for destination in needing where await stores.store(for: destination).isAvailable() {
            reachable.append(destination)
        }
        return reachable
    }

    private func performTick(announced: Set<UUID> = []) async throws -> TickResult {
        let config = try store.loadConfig()
        var state = try loadState(for: config)
        forgetRemovedSources(config)
        var runs: [RunRecord] = []
        var notices: [Notice] = []
        _ = await refreshCache(config: config, state: &state)
        var planned: [(Source, [Destination])] = []
        for source in config.sources where source.enabled && !source.needsHuman {
            let targets = await targets(of: source, config: config, state: state, now: time.now)
            if !targets.isEmpty { planned.append((source, targets)) }
        }
        var pending: [Source] = []
        for source in config.sources where source.enabled && source.needsHuman {
            if await !pendingTargets(of: source, config: config, state: state, now: time.now).isEmpty { pending.append(source) }
        }
        announce((planned.map(\.0) + pending).filter { !announced.contains($0.id) })
        for (source, targets) in planned {
            try await execute(source, targets, .scheduled, state: &state, runs: &runs)
        }
        for source in pending {
            try await execute(source, config.destinations(of: source), .catchUp, state: &state, runs: &runs)
        }
        for source in config.sources where source.enabled && source.needsHuman {
            try await advanceChain(source, config: config, mode: .tick, state: &state, runs: &runs, notices: &notices)
        }
        let unavailable = await refreshCache(config: config, state: &state)
        notices += failureNotices(runs) + (await reminderNotices(config: config, state: &state, unavailable: unavailable))
        try store.saveState(state)
        return TickResult(runs: runs, notices: notices)
    }

    private func performRunNow(sourceId: UUID) async throws -> TickResult {
        let config = try store.loadConfig()
        var state = try loadState(for: config)
        var runs: [RunRecord] = []
        guard let source = config.source(sourceId) else { return TickResult() }
        let destinations = config.destinations(of: source)
        guard !destinations.isEmpty else { return TickResult() }
        guard source.needsHuman else {
            try await execute(source, destinations, .manual, state: &state, runs: &runs)
            try store.saveState(state)
            return TickResult(runs: runs, notices: failureNotices(runs))
        }
        if state.sourceState(source.id).chain == nil {
            state.updateSource(source.id) { $0.armedAt = $0.armedAt ?? self.time.now }
            try store.saveState(state)
        }
        var notices: [Notice] = []
        try await advanceChain(source, config: config, mode: .runNow, state: &state, runs: &runs, notices: &notices)
        try store.saveState(state)
        return TickResult(runs: runs, notices: notices + failureNotices(runs))
    }

    private func performRunAllNow() async throws -> TickResult {
        let config = try store.loadConfig()
        var state = try loadState(for: config)
        var runs: [RunRecord] = []
        let sources = config.sources.filter { $0.enabled && !$0.needsHuman && !config.destinations(of: $0).isEmpty }
        announce(sources)
        for source in sources {
            try await execute(source, config.destinations(of: source), .manual, state: &state, runs: &runs)
        }
        var notices: [Notice] = []
        for source in config.sources where source.enabled && source.needsHuman {
            try await advanceChain(source, config: config, mode: .runAll, state: &state, runs: &runs, notices: &notices)
        }
        try store.saveState(state)
        return TickResult(runs: runs, notices: notices + failureNotices(runs))
    }

    /// The run will start working right away instead of waiting for a file or a device.
    private func startsWithoutWaiting(_ source: Source) -> Bool {
        guard let first = source.steps.first else { return false }
        return switch first.kind {
        case .folder, .command: true
        case .device: !chains.awaitsDevice(source, chain: nil)
        case .file: false
        }
    }

    private func enqueue<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let previous = queueTail
        let task = Task<Value, Error> {
            await previous?.value
            return try await operation()
        }
        queueTail = Task { _ = try? await task.value }
        return try await task.value
    }

    private func performConfirmPickup(sourceId: UUID) async throws -> TickResult {
        let config = try store.loadConfig()
        var state = try loadState(for: config)
        var runs: [RunRecord] = []
        guard let source = config.source(sourceId), source.needsHuman else { return TickResult() }
        var notices: [Notice] = []
        try await advanceChain(source, config: config, mode: .confirm, state: &state, runs: &runs, notices: &notices)
        return TickResult(runs: runs, notices: notices + failureNotices(runs))
    }

    private func forgetRemovedSources(_ config: Config) {
        let known = Set(config.sources.map(\.id))
        for id in chains.sourceIds() where !known.contains(id) {
            try? chains.discard(sourceId: id)
        }
        for id in inbox.sourceIds() where !known.contains(id) {
            try? inbox.removePackage(for: id, toTrash: true)
        }
    }

    private func announce(_ sources: [Source]) {
        guard !sources.isEmpty else { return }
        progress(.queued(sourceIds: sources.map(\.id)))
    }

    /// Only a run started by the button can be cancelled: waiting because it is due is a reminder, it stays until the backup.
    private func performCancelWaiting(sourceId: UUID) async throws -> TickResult {
        var state = try loadState(for: try store.loadConfig())
        if state.sourceState(sourceId).chain != nil {
            try chains.discard(sourceId: sourceId)
        }
        state.updateSource(sourceId) {
            $0.armedAt = nil
            $0.chain = nil
        }
        try store.saveState(state)
        return TickResult()
    }

    private func performRestartChain(sourceId: UUID) async throws -> TickResult {
        let now = time.now
        var state = try loadState(for: try store.loadConfig())
        try chains.discard(sourceId: sourceId)
        state.updateSource(sourceId) {
            $0.chain = nil
            $0.armedAt = now
        }
        try store.saveState(state)
        return TickResult()
    }

    private func advanceChain(
        _ source: Source,
        config: Config,
        mode: ChainMode,
        state: inout AppState,
        runs: inout [RunRecord],
        notices: inout [Notice]
    ) async throws {
        let destinations = config.destinations(of: source)
        guard !destinations.isEmpty, !source.steps.isEmpty else { return }
        var didWork = false
        while true {
            let sourceState = state.sourceState(source.id)
            let startedAt = time.now
            let opensWithoutWaiting = startsWithoutWaiting(source)
            let retryDue = sourceState.chain?.retryAfter.map { $0 <= startedAt } ?? false
            let permissions = ChainPermissions(
                mayStart: mode == .runNow
                    || (mode == .runAll && opensWithoutWaiting)
                    || planner.awaitsFile(source, state: sourceState, now: startedAt),
                mayRetry: ((mode == .runNow || mode == .confirm) && !didWork) || retryDue,
                mayConfirm: mode == .confirm || (mode == .runNow && !didWork),
                start: mode == .tick && sourceState.armedAt == nil ? .schedule : .button
            )
            let transition = await chains.advance(source, chain: sourceState.chain, lastPickup: sourceState.lastPickup, permissions: permissions)
            switch transition {
            case .stay:
                if didWork { progress(.finished(sourceId: source.id)) }
                return
            case let .moved(chain):
                didWork = true
                state.updateSource(source.id) {
                    if $0.chain == nil, chain != nil { $0.armedAt = nil }
                    $0.chain = chain
                }
                try store.saveState(state)
            case var .failed(chain):
                guard !quit.isQuitting else { return }
                if Self.retriesByItself(chain, in: source) {
                    chain.retryAfter = time.now.addingTimeInterval(SchedulePlanner.retryInterval)
                }
                let failedChain = chain
                state.updateSource(source.id) { $0.chain = failedChain }
                try store.saveState(state)
                let failure = RunRecord(
                    sourceId: source.id,
                    sourceName: source.name,
                    trigger: .pickup,
                    startedAt: startedAt,
                    finishedAt: time.now,
                    collectError: Self.stepFailure(failedChain, in: source)
                )
                try store.appendRun(failure)
                runs.append(failure)
                progress(.finished(sourceId: source.id))
                return
            case .completed:
                let runStartedAt = sourceState.chain?.startedAt ?? startedAt
                state.updateSource(source.id) {
                    $0.chain = nil
                    $0.lastPickup = runStartedAt
                    $0.armedAt = nil
                }
                try store.saveState(state)
                if source.hasDevice {
                    progress(.canUnplug(sourceId: source.id, sourceName: source.name))
                }
                try await execute(source, destinations, .pickup, state: &state, runs: &runs)
                return
            }
        }
    }

    /// A failed step retries by itself in an hour. Except a command after a manual step: it may have used up what the person prepared (one-time links).
    private static func retriesByItself(_ chain: ChainState, in source: Source) -> Bool {
        let steps = source.steps
        guard chain.stepIndex < steps.count else { return false }
        guard case .command = steps[chain.stepIndex].kind else { return true }
        return !steps[..<chain.stepIndex].contains(where: \.needsHuman)
    }

    private static func stepFailure(_ chain: ChainState, in source: Source) -> String {
        let steps = source.steps
        let index = min(chain.stepIndex, steps.count - 1)
        guard steps.count > 1 else { return chain.failure ?? "" }
        return SourceError.stepFailed(index: index, count: steps.count, name: steps[index].name, reason: chain.failure ?? "").localizedDescription
    }

    private func execute(_ source: Source, _ destinations: [Destination], _ trigger: RunTrigger, state: inout AppState, runs: inout [RunRecord]) async throws {
        let record = await engine.run(source: source, destinations: destinations, trigger: trigger)
        try register(record, trigger: trigger, state: &state, runs: &runs)
    }

    /// Once the app is quitting, a run's outcome is not recorded: its commands were stopped by the quit, not broken.
    private func register(_ record: RunRecord, trigger: RunTrigger, state: inout AppState, runs: inout [RunRecord]) throws {
        guard !quit.isQuitting else { return }
        reducer.apply(record, to: &state)
        try store.saveState(state)
        if record.isDeferredOnly && trigger != .manual { return }
        try store.appendRun(record)
        runs.append(record)
    }

    private func reminderNotices(config: Config, state: inout AppState, unavailable: Set<UUID>) async -> [Notice] {
        let now = time.now
        let report = await report(config: config, state: state, unavailable: unavailable, now: now)
        let reminded = reminders.dueReminders(in: report, state: state, now: now)
        reminders.record(reminded, report: report, state: &state, now: now)
        var notices: [Notice] = []
        for item in reminded {
            switch item {
            case let .manualExportDue(sourceId):
                if let source = config.source(sourceId) { notices.append(.manualExportDue(sourceId: sourceId, sourceName: source.name)) }
            case let .deviceDue(sourceId):
                if let source = config.source(sourceId) { notices.append(.deviceDue(sourceId: sourceId, sourceName: source.name)) }
            case let .connectDestination(destinationId):
                guard let destination = config.destination(destinationId) else { continue }
                let onlyHere = config.sources.filter { source in
                    source.enabled && source.destinationIds.contains(destinationId) && !config.destinations(of: source).contains { other in
                        other.id != destinationId && state.newestCopyDate(sourceId: source.id, destinationId: other.id) != nil
                    }
                }
                notices.append(.connectDestination(destinationId: destinationId, destinationName: destination.name, onlyCopyOf: onlyHere.map(\.name)))
            default:
                break
            }
        }
        return notices
    }

    private func failureNotices(_ runs: [RunRecord]) -> [Notice] {
        runs.compactMap { run in run.firstFailure.map { .runFailed(sourceId: run.sourceId, sourceName: run.sourceName, message: $0) } }
    }

    private func report(config: Config, state: AppState, unavailable: Set<UUID>, now: Date) async -> StatusReport {
        var scans: [UUID: InboxScan] = [:]
        var missingDevices: Set<UUID> = []
        for source in config.sources where source.enabled && source.needsHuman {
            let sourceState = state.sourceState(source.id)
            guard sourceState.chain != nil || planner.awaitsFile(source, state: sourceState, now: now) else { continue }
            scans[source.id] = chains.awaitedFiles(source, chain: sourceState.chain, lastPickup: sourceState.lastPickup)
            if chains.awaitsDevice(source, chain: sourceState.chain) { missingDevices.insert(source.id) }
        }
        return reporter.report(config: config, state: state, now: now, unavailableDestinations: unavailable, inboxScans: scans, missingDevices: missingDevices)
    }
}
