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

    /// Шаг человека в начале источника принимается, только когда его ждут: подошёл срок или нажата кнопка.
    public func awaitsFile(_ source: Source, state: SourceState, now: Date) -> Bool {
        guard state.armedAt == nil else { return true }
        return dueDate(for: source, state: state).map { $0 <= now } ?? false
    }

    public func isSeverelyOverdue(_ source: Source, state: SourceState, now: Date) -> Bool {
        guard state.lastRun != nil,
              let due = dueDate(for: source, state: state),
              let first = source.schedule.nextDue(after: due, calendar: calendar),
              let second = source.schedule.nextDue(after: first, calendar: calendar) else { return false }
        return now > second
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
        let reference = state.destinationState(destination.id).lastCaughtUp ?? earliestDebt
        return calendar.date(byAdding: .day, value: days, to: reference)
    }

    public func shouldVerify(_ destination: Destination, state: AppState, now: Date) -> Bool {
        guard case .rclone = destination.kind,
              let lastVerified = state.destinationState(destination.id).lastVerified else { return true }
        return lastVerified.addingTimeInterval(Self.remoteVerificationInterval) <= now
    }

    public func nextWake(config: Config, state: AppState, now: Date, needsAttention: Bool) -> Date? {
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
