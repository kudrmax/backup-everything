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

    private enum ChainMode {
        case tick
        case runAll
        case runNow
        case confirm
    }

    public init(
        store: Store,
        engine: BackupEngine,
        inbox: ManualExportInbox,
        chains: StepChainRunner,
        stores: any DestinationStoreFactory,
        time: any TimeSource,
        calendar: Calendar,
        quit: any QuitSignal = ProcessGroups.shared,
        progress: @escaping ProgressHandler = { _ in }
    ) {
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

    /// If another backup is running ahead, whatever the check will certainly do is marked “queued” right away, not when its turn comes.
    public func tick() async throws -> TickResult {
        var announced: Set<UUID> = []
        if let config = try? store.loadConfig(), let state = try? loadState(for: config, now: time.now) {
            let foreseen = await foreseenWork(config: config, state: state, now: time.now)
            announce(foreseen)
            announced = Set(foreseen.map(\.id))
        }
        return try await enqueue { [announced] in try await self.performTick(announced: announced) }
    }

    /// The source is marked “queued” right away, even if another backup is running now.
    public func runNow(sourceId: UUID) async throws -> TickResult {
        if let config = try? store.loadConfig(), let source = config.source(sourceId),
           !config.destinations(of: source).isEmpty, startsWithoutWaiting(source) {
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

    /// Sources the check will certainly run: due by schedule, or owing an available local folder a copy that can be caught up.
    private func foreseenWork(config: Config, state: AppState, now: Date) async -> [Source] {
        let due = Set(planner.dueAutomaticSources(config: config, state: state, now: now).map(\.id))
        let retryable = planner.retryableDebts(state: state, now: now)
        var work: [Source] = []
        for source in config.sources where source.enabled {
            if due.contains(source.id) {
                work.append(source)
                continue
            }
            let sourceState = state.sourceState(source.id)
            guard sourceState.lastRun != nil else { continue }
            let owed = config.destinations(of: source).filter { destination in
                if state.hasDebt(sourceId: source.id, destinationId: destination.id) {
                    return retryable.contains { $0.sourceId == source.id && $0.destinationId == destination.id }
                }
                return state.lastDeliveredSnapshot(sourceId: source.id, destinationId: destination.id) == nil
            }
            var reachable = false
            for destination in owed {
                guard case .localFolder = destination.kind else { continue }
                if await stores.store(for: destination).isAvailable() {
                    reachable = true
                    break
                }
            }
            guard reachable else { continue }
            let hasCopy = config.destinations(of: source).contains { other in
                !owed.contains(other) && state.lastDeliveredSnapshot(sourceId: source.id, destinationId: other.id) != nil
            }
            if !source.needsHuman || hasCopy || inbox.pendingPackage(for: source.id) != nil {
                work.append(source)
            }
        }
        return work
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

    public func confirmPickup(sourceId: UUID) async throws -> TickResult {
        try await enqueue { try await self.performConfirmPickup(sourceId: sourceId) }
    }

    public func restartChain(sourceId: UUID) async throws -> TickResult {
        try await enqueue { try await self.performRestartChain(sourceId: sourceId) }
    }

    public func cancelWaiting(sourceId: UUID) async throws -> TickResult {
        try await enqueue { try await self.performCancelWaiting(sourceId: sourceId) }
    }

    public func statusReport() async throws -> StatusReport {
        try await currentStatus().report
    }

    /// The settings, the state as it stands against them and the status built from both: what the window shows.
    public func currentStatus() async throws -> CurrentStatus {
        let config = try store.loadConfig()
        let now = time.now
        let state = try loadState(for: config, now: now)
        return CurrentStatus(config: config, state: state, report: await report(config: config, state: state, now: now))
    }

    public func nextWake() async throws -> Date? {
        let config = try store.loadConfig()
        let now = time.now
        let state = try loadState(for: config, now: now)
        let report = await report(config: config, state: state, now: now)
        return planner.nextWake(config: config, state: state, now: now, needsAttention: report.overall != .ok)
    }

    /// The saved state brought in line with the settings: facts of places the destinations no longer point to are gone.
    private func loadState(for config: Config, now: Date) throws -> AppState {
        var state = try store.loadState()
        reducer.reconcile(config: config, state: &state, now: now)
        return state
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

    private func performTick(announced: Set<UUID> = []) async throws -> TickResult {
        let config = try store.loadConfig()
        let now = time.now
        var state = try loadState(for: config, now: now)
        forgetRemovedSources(config)
        let debtorsBefore = Set(state.pausingDisabledSources(of: config).debts.map(\.destinationId))
        var runs: [RunRecord] = []
        let missing = await verifyCopies(config: config, state: &state, now: now)

        let due = planner.dueAutomaticSources(config: config, state: state, now: now)
        let dueIds = Set(due.map(\.id))
        let retryableSourceIds = Set(planner.retryableDebts(state: state, now: now).map(\.sourceId))
        var catchUps: [Source] = []
        var copies: [CopyPlan] = []
        for source in config.sources where source.enabled && !dueIds.contains(source.id) {
            guard retryableSourceIds.contains(source.id) else { continue }
            let debtors = state.debts.filter { $0.sourceId == source.id }.compactMap { config.destination($0.destinationId) }
            var reachable: [Destination] = []
            for destination in debtors where await stores.store(for: destination).isAvailable() {
                reachable.append(destination)
            }
            guard !reachable.isEmpty else { continue }
            if source.needsHuman, inbox.pendingPackage(for: source.id) != nil {
                catchUps.append(source)
            } else if let newest = await newestCopy(of: source, config: config, excluding: Set(debtors.map(\.id))) {
                copies.append(CopyPlan(source: source, snapshot: newest.snapshot, origin: newest.origin, targets: reachable))
            } else if source.needsHuman {
                for index in state.debts.indices where state.debts[index].sourceId == source.id {
                    state.debts[index].lastAttempt = now
                }
            } else {
                catchUps.append(source)
            }
        }
        announce((copies.map(\.source) + catchUps + due).filter { !announced.contains($0.id) })
        for plan in copies {
            let record = await engine.copy(plan.snapshot, of: plan.source, from: plan.origin, to: plan.targets)
            try register(record, trigger: .catchUp, config: config, state: &state, runs: &runs)
        }
        for source in catchUps {
            let debtors = state.debts.filter { $0.sourceId == source.id }.compactMap { config.destination($0.destinationId) }
            try await execute(source, debtors, .catchUp, config: config, state: &state, runs: &runs)
        }
        for source in due {
            try await execute(source, config.destinations(of: source), .scheduled, config: config, state: &state, runs: &runs)
        }
        var runNotices: [Notice] = []
        for source in config.sources where source.enabled && source.needsHuman {
            try await advanceChain(source, config: config, mode: .tick, state: &state, runs: &runs, notices: &runNotices)
        }

        let notices = missing + runNotices + (await closingNotices(config: config, state: &state, runs: runs, debtorsBefore: debtorsBefore))
        try store.saveState(state)
        return TickResult(runs: runs, notices: notices)
    }

    private func performRunNow(sourceId: UUID) async throws -> TickResult {
        let config = try store.loadConfig()
        var state = try loadState(for: config, now: time.now)
        var runs: [RunRecord] = []
        guard let source = config.source(sourceId) else { return TickResult() }
        let destinations = config.destinations(of: source)
        guard !destinations.isEmpty else { return TickResult() }
        guard source.needsHuman else {
            try await execute(source, destinations, .manual, config: config, state: &state, runs: &runs)
            return TickResult(runs: runs, notices: failureNotices(runs))
        }
        if state.sourceState(source.id).chain == nil {
            state.updateSource(source.id) { $0.armedAt = $0.armedAt ?? self.time.now }
            try store.saveState(state)
        }
        var notices: [Notice] = []
        try await advanceChain(source, config: config, mode: .runNow, state: &state, runs: &runs, notices: &notices)
        return TickResult(runs: runs, notices: notices + failureNotices(runs))
    }

    private func performRunAllNow() async throws -> TickResult {
        let config = try store.loadConfig()
        var state = try loadState(for: config, now: time.now)
        var runs: [RunRecord] = []
        let sources = config.sources.filter { $0.enabled && !$0.needsHuman && !config.destinations(of: $0).isEmpty }
        announce(sources)
        for source in sources {
            try await execute(source, config.destinations(of: source), .manual, config: config, state: &state, runs: &runs)
        }
        var notices: [Notice] = []
        for source in config.sources where source.enabled && source.needsHuman {
            try await advanceChain(source, config: config, mode: .runAll, state: &state, runs: &runs, notices: &notices)
        }
        return TickResult(runs: runs, notices: notices + failureNotices(runs))
    }

    private func performConfirmPickup(sourceId: UUID) async throws -> TickResult {
        let config = try store.loadConfig()
        var state = try loadState(for: config, now: time.now)
        var runs: [RunRecord] = []
        guard let source = config.source(sourceId), source.needsHuman else { return TickResult() }
        var notices: [Notice] = []
        try await advanceChain(source, config: config, mode: .confirm, state: &state, runs: &runs, notices: &notices)
        return TickResult(runs: runs, notices: notices + failureNotices(runs))
    }

    private func verifyCopies(config: Config, state: inout AppState, now: Date) async -> [Notice] {
        var notices: [Notice] = []
        var history: [RunRecord]?
        for destination in config.destinations where planner.shouldVerify(destination, state: state, now: now) {
            let sources = config.sources.filter { source in
                source.enabled
                    && source.destinationIds.contains(destination.id)
                    && state.sourceState(source.id).lastRun != nil
                    && !state.hasDebt(sourceId: source.id, destinationId: destination.id)
            }
            guard !sources.isEmpty else { continue }
            let destinationStore = stores.store(for: destination)
            guard await destinationStore.isAvailable() else { continue }
            for source in sources {
                guard let present = try? await destinationStore.listSnapshots(sourceSlug: source.slug) else { continue }
                var expected = state.lastDeliveredSnapshot(sourceId: source.id, destinationId: destination.id)
                if expected == nil {
                    if history == nil { history = store.loadRuns() }
                    let since = state.copyExpectedSince(sourceId: source.id, destinationId: destination.id) ?? .distantPast
                    expected = history?.first { run in
                        run.sourceId == source.id && run.startedAt >= since && run.deliveries.contains {
                            $0.destinationId == destination.id && $0.outcome.isDelivered
                        }
                    }?.snapshotName
                }
                let proven: Snapshot?
                if let expected {
                    proven = present.first { $0.name == expected }
                } else {
                    guard let own = try? await destinationStore.copies(of: source) else { continue }
                    proven = own.max { $0.date < $1.date }
                }
                if let proven {
                    if state.deliveredCopyDate(sourceId: source.id, destinationId: destination.id) == nil
                        || state.lastDeliveredSnapshot(sourceId: source.id, destinationId: destination.id) == nil {
                        state.recordDelivery(sourceId: source.id, destinationId: destination.id, snapshotName: proven.name, collectedAt: proven.date)
                    }
                    continue
                }
                let elsewhere = config.destinations(of: source).contains { other in
                    other.id != destination.id && state.lastDeliveredSnapshot(sourceId: source.id, destinationId: other.id) != nil
                }
                state.debts.append(Debt(sourceId: source.id, destinationId: destination.id, since: now, elsewhere: elsewhere))
                state.forgetDelivery(sourceId: source.id, destinationId: destination.id)
                if expected != nil {
                    notices.append(.copiesMissing(sourceId: source.id, sourceName: source.name, destinationName: destination.name))
                }
            }
            state.updateDestination(destination.id) { $0.lastVerified = now }
        }
        return notices
    }

    private struct CopyPlan {
        let source: Source
        let snapshot: Snapshot
        let origin: Destination
        let targets: [Destination]
    }

    /// The newest copy of the source on an available destination that is not behind. On a tie, the local one wins.
    private func newestCopy(of source: Source, config: Config, excluding debtors: Set<UUID>) async -> (snapshot: Snapshot, origin: Destination)? {
        var best: (snapshot: Snapshot, origin: Destination)?
        for destination in config.destinations(of: source) where !debtors.contains(destination.id) {
            let destinationStore = stores.store(for: destination)
            guard await destinationStore.isAvailable(),
                  let newest = (try? await destinationStore.copies(of: source))?.max(by: { $0.date < $1.date }) else { continue }
            if let current = best {
                let isLocal = if case .localFolder = destination.kind { true } else { false }
                guard newest.date > current.snapshot.date || (newest.date == current.snapshot.date && isLocal) else { continue }
            }
            best = (newest, destination)
        }
        return best
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
        var state = try store.loadState()
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
        var state = try store.loadState()
        try chains.discard(sourceId: sourceId)
        let now = time.now
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
                for destination in destinations where !state.hasDebt(sourceId: source.id, destinationId: destination.id) {
                    state.debts.append(Debt(sourceId: source.id, destinationId: destination.id, since: startedAt))
                }
                try store.saveState(state)
                if source.hasDevice {
                    progress(.canUnplug(sourceId: source.id, sourceName: source.name))
                }
                try await execute(source, destinations, .pickup, config: config, state: &state, runs: &runs)
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

    private func execute(
        _ source: Source,
        _ destinations: [Destination],
        _ trigger: RunTrigger,
        config: Config,
        state: inout AppState,
        runs: inout [RunRecord]
    ) async throws {
        let record = await engine.run(source: source, destinations: destinations, trigger: trigger)
        try register(record, trigger: trigger, config: config, state: &state, runs: &runs)
    }

    /// Once the app is quitting, a run's outcome is not recorded: its commands were stopped by the quit, not broken.
    /// Nothing is lost: the next launch finds the run still due, or its debts still open, and does it again.
    private func register(_ record: RunRecord, trigger: RunTrigger, config: Config, state: inout AppState, runs: inout [RunRecord]) throws {
        guard !quit.isQuitting else { return }
        reducer.apply(record, to: &state, config: config)
        try store.saveState(state)
        if record.isDeferredOnly && trigger != .manual { return }
        try store.appendRun(record)
        runs.append(record)
    }

    private func closingNotices(
        config: Config,
        state: inout AppState,
        runs: [RunRecord],
        debtorsBefore: Set<UUID>
    ) async -> [Notice] {
        var notices = failureNotices(runs)
        let active = state.pausingDisabledSources(of: config)
        for destination in config.destinations where debtorsBefore.contains(destination.id) {
            guard case .days = destination.expectedEvery, active.debts(forDestination: destination.id).isEmpty else { continue }
            notices.append(.destinationCaughtUp(destinationId: destination.id, destinationName: destination.name))
        }
        let now = time.now
        let report = await report(config: config, state: state, now: now)
        let reminded = reminders.dueReminders(in: report, state: state, now: now)
        reminders.record(reminded, report: report, state: &state, now: now)
        for item in reminded {
            switch item {
            case let .manualExportDue(sourceId):
                if let source = config.source(sourceId) {
                    notices.append(.manualExportDue(sourceId: sourceId, sourceName: source.name))
                }
            case let .deviceDue(sourceId):
                if let source = config.source(sourceId) {
                    notices.append(.deviceDue(sourceId: sourceId, sourceName: source.name))
                }
            case let .connectDestination(destinationId):
                if let destination = config.destination(destinationId) {
                    let unique = Set(active.debts(forDestination: destinationId).filter { !$0.elsewhere }.map(\.sourceId))
                    let names = config.sources.filter { unique.contains($0.id) }.map(\.name)
                    notices.append(.connectDestination(destinationId: destinationId, destinationName: destination.name, onlyCopyOf: names))
                }
            default:
                break
            }
        }
        return notices
    }

    private func failureNotices(_ runs: [RunRecord]) -> [Notice] {
        runs.compactMap { run in
            run.firstFailure.map { .runFailed(sourceId: run.sourceId, sourceName: run.sourceName, message: $0) }
        }
    }

    private func report(config: Config, state: AppState, now: Date) async -> StatusReport {
        var unavailable: Set<UUID> = []
        let active = state.pausingDisabledSources(of: config)
        for destination in config.destinations where !active.debts(forDestination: destination.id).isEmpty {
            if !(await stores.store(for: destination).isAvailable()) {
                unavailable.insert(destination.id)
            }
        }
        var scans: [UUID: InboxScan] = [:]
        var missingDevices: Set<UUID> = []
        for source in config.sources where source.enabled && source.needsHuman {
            let sourceState = state.sourceState(source.id)
            guard sourceState.chain != nil || planner.awaitsFile(source, state: sourceState, now: now) else { continue }
            scans[source.id] = chains.awaitedFiles(source, chain: sourceState.chain, lastPickup: sourceState.lastPickup)
            if chains.awaitsDevice(source, chain: sourceState.chain) { missingDevices.insert(source.id) }
        }
        return reporter.report(
            config: config,
            state: state,
            now: now,
            unavailableDestinations: unavailable,
            inboxScans: scans,
            missingDevices: missingDevices
        )
    }
}
