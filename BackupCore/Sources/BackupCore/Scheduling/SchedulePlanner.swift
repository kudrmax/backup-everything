import Foundation

public struct SchedulePlanner: Sendable {
    public static let retryInterval: TimeInterval = 3600

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
        return mayRetry(state, now: now)
    }

    public func mayRetry(_ state: SourceState, now: Date) -> Bool {
        state.retryAfter.map { $0 <= now } ?? true
    }

    /// A manual step at the start of a source is accepted only when it is awaited: the time has come or the button was pressed.
    public func awaitsFile(_ source: Source, state: SourceState, now: Date) -> Bool {
        state.armedAt != nil || dueDateReached(source, state: state, now: now)
    }

    public func dueDateReached(_ source: Source, state: SourceState, now: Date) -> Bool {
        dueDate(for: source, state: state).map { $0 <= now } ?? false
    }

    /// Destinations of the source whose newest copy is older than one interval of the schedule, or that hold none.
    /// `newest` tells the date of the newest copy on a destination. A source without a schedule needs nothing by itself.
    public func destinationsNeedingCopy(of source: Source, in config: Config, newest: (UUID) -> Date?, now: Date) -> [Destination] {
        guard source.enabled, source.schedule != .manual else { return [] }
        return config.destinations(of: source).filter { destination in
            guard let copiedAt = newest(destination.id),
                  let next = source.schedule.nextDue(after: copiedAt, calendar: calendar) else { return true }
            return next <= now
        }
    }

    /// Whether the newest copy on the destination is within its rhythm (5.5): on a disk that can stay unplugged, until
    /// its connect deadline; elsewhere, until the next backup by the schedule plus the time a run takes.
    public func isCopyFresh(_ source: Source, on destination: Destination, copiedAt: Date?, now: Date) -> Bool {
        guard let copiedAt else { return false }
        switch destination.expectedEvery {
        case .days:
            return connectDeadline(for: destination, newestCopy: copiedAt).map { $0 > now } ?? true
        case .always:
            guard let next = source.schedule.nextDue(after: copiedAt, calendar: calendar) else { return true }
            return next.addingTimeInterval(Self.retryInterval) > now
        }
    }

    /// When a “from time to time” disk should be connected again: its interval after the newest copy on it.
    public func connectDeadline(for destination: Destination, newestCopy: Date?) -> Date? {
        guard case let .days(days) = destination.expectedEvery, let newestCopy else { return nil }
        return calendar.date(byAdding: .day, value: days, to: newestCopy)
    }

    /// Long overdue: two backups by the schedule were missed after the end of the rhythm of every copy of the source.
    /// Without any copy, each destination counts from the creation of the source.
    public func isSeverelyOverdue(_ source: Source, on destinations: [Destination], newest: (UUID) -> Date?, hasRun: Bool, now: Date) -> Bool {
        guard source.enabled, hasRun, !destinations.isEmpty else { return false }
        let deadlines = destinations.map { severeDeadline(source, on: $0, copiedAt: newest($0.id) ?? source.createdAt) }
        guard deadlines.allSatisfy({ $0 != nil }) else { return false }
        return deadlines.compactMap { $0 }.allSatisfy { now > $0 }
    }

    private func severeDeadline(_ source: Source, on destination: Destination, copiedAt: Date) -> Date? {
        guard let due = source.schedule.nextDue(after: copiedAt, calendar: calendar) else { return nil }
        let rhythmEnd = max(due, connectDeadline(for: destination, newestCopy: copiedAt) ?? due)
        guard let first = source.schedule.nextDue(after: rhythmEnd, calendar: calendar) else { return nil }
        return source.schedule.nextDue(after: first, calendar: calendar)
    }

    public func nextWake(config: Config, state: AppState, now: Date, needsAttention: Bool) -> Date? {
        var candidates: [Date] = []
        for source in config.sources where source.enabled {
            let sourceState = state.sourceState(source.id)
            if let retryAfter = sourceState.retryAfter { candidates.append(retryAfter) }
            for destination in config.destinations(of: source) {
                guard let copiedAt = state.newestCopyDate(sourceId: source.id, destinationId: destination.id) else { continue }
                if let next = source.schedule.nextDue(after: copiedAt, calendar: calendar) { candidates.append(next) }
                if let deadline = connectDeadline(for: destination, newestCopy: copiedAt) { candidates.append(deadline) }
            }
            if let due = dueDate(for: source, state: sourceState) { candidates.append(due) }
        }
        if needsAttention { candidates.append(now.addingTimeInterval(Self.retryInterval)) }
        return candidates.filter { $0 > now }.min()
    }
}
