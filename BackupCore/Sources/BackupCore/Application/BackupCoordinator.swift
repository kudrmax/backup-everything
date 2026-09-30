import Foundation

public actor BackupCoordinator {
    private let store: Store
    private let engine: BackupEngine
    private let inbox: ManualExportInbox
    private let stores: any DestinationStoreFactory
    private let time: any TimeSource
    private let progress: ProgressHandler
    private let planner: SchedulePlanner
    private let reporter: StatusReporter
    private let reminders = ReminderPlanner()
    private let reducer = StateReducer()
    private var queueTail: Task<Void, Never>?

    public init(
        store: Store,
        engine: BackupEngine,
        inbox: ManualExportInbox,
        stores: any DestinationStoreFactory,
        time: any TimeSource,
        calendar: Calendar,
        progress: @escaping ProgressHandler = { _ in }
    ) {
        self.store = store
        self.engine = engine
        self.inbox = inbox
        self.stores = stores
        self.time = time
        self.progress = progress
        self.planner = SchedulePlanner(calendar: calendar)
        self.reporter = StatusReporter(planner: planner)
    }

    public func tick() async throws -> TickResult {
        try await enqueue { try await self.performTick() }
    }

    public func runNow(sourceId: UUID) async throws -> TickResult {
        try await enqueue { try await self.performRunNow(sourceId: sourceId) }
    }

    public func runAllNow() async throws -> TickResult {
        try await enqueue { try await self.performRunAllNow() }
    }

    public func confirmPickup(sourceId: UUID) async throws -> TickResult {
        try await enqueue { try await self.performConfirmPickup(sourceId: sourceId) }
    }

    public func statusReport() async throws -> StatusReport {
        let config = try store.loadConfig()
        let state = try store.loadState()
        return await report(config: config, state: state, now: time.now)
    }

    public func nextWake() async throws -> Date? {
        let config = try store.loadConfig()
        let state = try store.loadState()
        let now = time.now
        let report = await report(config: config, state: state, now: now)
        return planner.nextWake(config: config, state: state, now: now, needsAttention: report.overall != .ok)
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

    private func performTick() async throws -> TickResult {
        let config = try store.loadConfig()
        var state = try store.loadState()
        reducer.dropOrphans(config: config, state: &state)
        let now = time.now
        let debtorsBefore = Set(state.debts.map(\.destinationId))
        var runs: [RunRecord] = []
        let missing = await verifyCopies(config: config, state: &state, now: now)

        let due = planner.dueAutomaticSources(config: config, state: state, now: now)
        let dueIds = Set(due.map(\.id))
        let retryableSourceIds = Set(planner.retryableDebts(state: state, now: now).map(\.sourceId))
        var catchUps: [Source] = []
        for source in config.sources where source.enabled && !dueIds.contains(source.id) {
            guard retryableSourceIds.contains(source.id) else { continue }
            if source.deliversFromPending, inbox.pendingPackage(for: source.id) == nil {
                state.debts.removeAll { $0.sourceId == source.id }
                continue
            }
            catchUps.append(source)
        }
        announce(catchUps + due)
        for source in catchUps {
            let debtors = state.debts.filter { $0.sourceId == source.id }.compactMap { config.destination($0.destinationId) }
            try await execute(source, debtors, .catchUp, state: &state, runs: &runs)
        }
        for source in config.sources where source.enabled {
            guard case let .manualExport(_, _, fileMode, _) = source.kind, fileMode == .single else { continue }
            try await pickUp(source, config: config, respectRetryDelay: true, state: &state, runs: &runs)
        }
        for source in due {
            try await execute(source, config.destinations(of: source), .scheduled, state: &state, runs: &runs)
        }

        let notices = missing + (await closingNotices(config: config, state: &state, runs: runs, debtorsBefore: debtorsBefore))
        try store.saveState(state)
        return TickResult(runs: runs, notices: notices)
    }

    private func performRunNow(sourceId: UUID) async throws -> TickResult {
        let config = try store.loadConfig()
        var state = try store.loadState()
        var runs: [RunRecord] = []
        guard let source = config.source(sourceId) else { return TickResult() }
        let destinations = config.destinations(of: source)
        guard !destinations.isEmpty else { return TickResult() }
        if source.deliversFromPending {
            try await pickUp(source, config: config, respectRetryDelay: false, state: &state, runs: &runs)
        } else {
            try await execute(source, destinations, .manual, state: &state, runs: &runs)
        }
        return TickResult(runs: runs, notices: failureNotices(runs))
    }

    private func performRunAllNow() async throws -> TickResult {
        let config = try store.loadConfig()
        var state = try store.loadState()
        var runs: [RunRecord] = []
        let sources = config.sources.filter { $0.enabled && !$0.deliversFromPending && !config.destinations(of: $0).isEmpty }
        announce(sources)
        for source in sources {
            try await execute(source, config.destinations(of: source), .manual, state: &state, runs: &runs)
        }
        return TickResult(runs: runs, notices: failureNotices(runs))
    }

    private func performConfirmPickup(sourceId: UUID) async throws -> TickResult {
        let config = try store.loadConfig()
        var state = try store.loadState()
        var runs: [RunRecord] = []
        guard let source = config.source(sourceId) else { return TickResult() }
        try await pickUp(source, config: config, respectRetryDelay: false, state: &state, runs: &runs)
        return TickResult(runs: runs, notices: failureNotices(runs))
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
                    expected = history?.first { run in
                        run.sourceId == source.id && run.deliveries.contains {
                            $0.destinationId == destination.id && $0.outcome.isDelivered
                        }
                    }?.snapshotName
                }
                let isIntact = expected.map { name in present.contains { $0.name == name } } ?? !present.isEmpty
                guard !isIntact else { continue }
                state.debts.append(Debt(sourceId: source.id, destinationId: destination.id, since: now))
                state.lastDelivered[AppState.deliveryKey(sourceId: source.id, destinationId: destination.id)] = nil
                if expected != nil {
                    notices.append(.copiesMissing(sourceId: source.id, sourceName: source.name, destinationName: destination.name))
                }
            }
            state.updateDestination(destination.id) { $0.lastVerified = now }
        }
        return notices
    }

    private func announce(_ sources: [Source]) {
        guard !sources.isEmpty else { return }
        progress(.queued(sourceIds: sources.map(\.id)))
    }

    private func pickUp(
        _ source: Source,
        config: Config,
        respectRetryDelay: Bool,
        state: inout AppState,
        runs: inout [RunRecord]
    ) async throws {
        guard case let .manualExport(watchPath, filePattern, _, removeOriginal) = source.kind else { return }
        let destinations = config.destinations(of: source)
        guard !destinations.isEmpty else { return }
        let now = time.now
        let sourceState = state.sourceState(source.id)
        if respectRetryDelay, let retryAfter = sourceState.retryAfter, retryAfter > now { return }
        let scan = inbox.scan(watchPath: watchPath, filePattern: filePattern, since: sourceState.lastPickup ?? source.createdAt, now: now)
        guard scan.isReady else { return }
        do {
            _ = try inbox.pickUp(sourceId: source.id, files: scan.files, removeOriginal: removeOriginal, at: now)
        } catch {
            let failure = RunRecord(
                sourceId: source.id,
                sourceName: source.name,
                trigger: .pickup,
                startedAt: now,
                finishedAt: now,
                collectError: "Не удалось забрать файлы: \(error.localizedDescription)"
            )
            try register(failure, trigger: .pickup, state: &state, runs: &runs)
            return
        }
        state.updateSource(source.id) { $0.lastPickup = now }
        try store.saveState(state)
        try await execute(source, destinations, .pickup, state: &state, runs: &runs)
    }

    private func execute(
        _ source: Source,
        _ destinations: [Destination],
        _ trigger: RunTrigger,
        state: inout AppState,
        runs: inout [RunRecord]
    ) async throws {
        let record = await engine.run(source: source, destinations: destinations, trigger: trigger)
        try register(record, trigger: trigger, state: &state, runs: &runs)
    }

    private func register(_ record: RunRecord, trigger: RunTrigger, state: inout AppState, runs: inout [RunRecord]) throws {
        reducer.apply(record, to: &state)
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
        for destination in config.destinations where debtorsBefore.contains(destination.id) {
            guard case .days = destination.expectedEvery, state.debts(forDestination: destination.id).isEmpty else { continue }
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
            case let .connectDestination(destinationId):
                if let destination = config.destination(destinationId) {
                    notices.append(.connectDestination(destinationId: destinationId, destinationName: destination.name))
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
        for destination in config.destinations where !state.debts(forDestination: destination.id).isEmpty {
            if !(await stores.store(for: destination).isAvailable()) {
                unavailable.insert(destination.id)
            }
        }
        var scans: [UUID: InboxScan] = [:]
        for source in config.sources where source.enabled {
            guard case let .manualExport(watchPath, filePattern, _, _) = source.kind else { continue }
            let since = state.sourceState(source.id).lastPickup ?? source.createdAt
            scans[source.id] = inbox.scan(watchPath: watchPath, filePattern: filePattern, since: since, now: now)
        }
        return reporter.report(config: config, state: state, now: now, unavailableDestinations: unavailable, inboxScans: scans)
    }
}
