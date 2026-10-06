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

    /// Long overdue: two backups by the schedule were missed after the end of the rhythm of every copy the source has, on
    /// each destination by that destination's rhythm (as for freshness, `isCopyFresh`): the next backup for an always
    /// connected one, the connect interval for a disk that can stay unplugged. A run that delivered nothing is no backup.
    /// Without any copy, each destination counts from the moment it was expected to hold one: its addition to the source
    /// or its move (`expectedSince`), else the creation of the source; so a new destination is “no copy yet”, not red.
    /// A source that has never run, or runs only by hand, is never long overdue.
    public func isSeverelyOverdue(_ source: Source, on destinations: [Destination], state: AppState, now: Date) -> Bool {
        guard source.enabled, state.sourceState(source.id).lastRun != nil else { return false }
        let copies = destinations.compactMap { destination in
            state.deliveredCopyDate(sourceId: source.id, destinationId: destination.id).map { (destination, $0) }
        }
        let references = copies.isEmpty
            ? destinations.map { ($0, state.copyExpectedSince(sourceId: source.id, destinationId: $0.id) ?? source.createdAt) }
            : copies
        let deadlines = references.map { severeDeadline(source, on: $0.0, copiedAt: $0.1) }
        guard !deadlines.isEmpty, deadlines.allSatisfy({ $0 != nil }) else { return false }
        return deadlines.compactMap { $0 }.allSatisfy { now > $0 }
    }

    private func severeDeadline(_ source: Source, on destination: Destination, copiedAt: Date) -> Date? {
        guard let due = source.schedule.nextDue(after: copiedAt, calendar: calendar) else { return nil }
        var rhythmEnd = due
        if case let .days(days) = destination.expectedEvery, let connect = calendar.date(byAdding: .day, value: days, to: copiedAt) {
            rhythmEnd = max(due, connect)
        }
        guard let first = source.schedule.nextDue(after: rhythmEnd, calendar: calendar) else { return nil }
        return source.schedule.nextDue(after: first, calendar: calendar)
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
