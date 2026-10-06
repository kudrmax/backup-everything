import Foundation

public struct SchedulePlanner: Sendable {
    public static let retryInterval: TimeInterval = 3600
    public static let remoteVerificationInterval: TimeInterval = 86_400

    private let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    public func dueDate(for source: Source, state: SourceState) -> Date? {
        guard source.enabled, source.schedule != .manual else { return nil }
        guard let lastRun = state.lastRun else { return source.createdAt }
        return source.schedule.nextDue(after: lastRun, calendar: calendar)
    }

    public func isDue(_ source: Source, state: SourceState, now: Date) -> Bool {
        guard let due = dueDate(for: source, state: state), due <= now else { return false }
        if let retryAfter = state.retryAfter, retryAfter > now { return false }
        return true
    }

    /// A manual step at the start of a source is accepted only when it is awaited: the time has come or the button was pressed.
    public func awaitsFile(_ source: Source, state: SourceState, now: Date) -> Bool {
        state.armedAt != nil || dueDateReached(source, state: state, now: now)
    }

    public func dueDateReached(_ source: Source, state: SourceState, now: Date) -> Bool {
        dueDate(for: source, state: state).map { $0 <= now } ?? false
    }

    /// Counted from the newest copy delivered anywhere, not from the last run: a run that delivered nothing is no backup.
    /// A source that has never delivered a copy counts from its creation; one that has never run is not overdue.
    public func isSeverelyOverdue(_ source: Source, state: SourceState, newestCopy: Date?, now: Date) -> Bool {
        guard source.enabled, state.lastRun != nil,
              let due = source.schedule.nextDue(after: newestCopy ?? source.createdAt, calendar: calendar),
              let first = source.schedule.nextDue(after: due, calendar: calendar),
              let second = source.schedule.nextDue(after: first, calendar: calendar) else { return false }
        return now > second
    }

    /// Whether the newest copy of the source on the destination is within the destination's rhythm (5.5). A disk that
    /// can stay unplugged keeps its copy fresh until its connect deadline. On an always-connected destination the copy
    /// stays fresh until the next backup by the schedule, counted from the moment the copy was collected, plus
    /// `retryInterval` for the run to finish; for a source without a schedule, until a newer copy is owed to it.
    public func isCopyFresh(_ source: Source, on destination: Destination, copiedAt: Date?, state: AppState, now: Date) -> Bool {
        guard let copiedAt else { return false }
        let owed = state.hasDebt(sourceId: source.id, destinationId: destination.id)
        switch destination.expectedEvery {
        case .days:
            guard owed, let deadline = connectDeadline(for: destination, state: state) else { return true }
            return deadline > now
        case .always:
            guard let next = source.schedule.nextDue(after: copiedAt, calendar: calendar) else { return !owed }
            return next.addingTimeInterval(Self.retryInterval) > now
        }
    }

    public func dueAutomaticSources(config: Config, state: AppState, now: Date) -> [Source] {
        config.sources.filter { source in
            !source.needsHuman
                && !config.destinations(of: source).isEmpty
                && isDue(source, state: state.sourceState(source.id), now: now)
        }
    }

    public func retryableDebts(state: AppState, now: Date) -> [Debt] {
        state.debts.filter { debt in
            guard let lastAttempt = debt.lastAttempt else { return true }
            return lastAttempt.addingTimeInterval(Self.retryInterval) <= now
        }
    }

    public func connectDeadline(for destination: Destination, state: AppState) -> Date? {
        guard case let .days(days) = destination.expectedEvery,
              let earliestDebt = state.debts(forDestination: destination.id).map(\.since).min() else { return nil }
        if let firstUnique = state.debts(forDestination: destination.id).filter({ !$0.elsewhere }).map(\.since).min() {
            return firstUnique
        }
        let reference = state.destinationState(destination.id).lastCaughtUp ?? earliestDebt
        return calendar.date(byAdding: .day, value: days, to: reference)
    }

    public func shouldVerify(_ destination: Destination, state: AppState, now: Date) -> Bool {
        guard case .rclone = destination.kind,
              let lastVerified = state.destinationState(destination.id).lastVerified else { return true }
        return lastVerified.addingTimeInterval(Self.remoteVerificationInterval) <= now
    }

    public func nextWake(config: Config, state: AppState, now: Date, needsAttention: Bool) -> Date? {
        let state = state.pausingDisabledSources(of: config)
        var candidates: [Date] = []
        for source in config.sources {
            let sourceState = state.sourceState(source.id)
            guard let due = dueDate(for: source, state: sourceState) else { continue }
            candidates.append(max(due, sourceState.retryAfter ?? due))
        }
        candidates.append(contentsOf: config.destinations.compactMap { connectDeadline(for: $0, state: state) })
        if needsAttention {
            candidates.append(now.addingTimeInterval(Self.retryInterval))
        }
        return candidates.filter { $0 > now }.min()
    }
}
