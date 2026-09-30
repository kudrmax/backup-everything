import Foundation

public struct ReminderPlanner: Sendable {
    public static let repeatInterval: TimeInterval = 86_400

    public init() {}

    public func dueReminders(in report: StatusReport, state: AppState, now: Date) -> [AttentionItem] {
        report.items.filter { item in
            guard let key = key(for: item) else { return false }
            guard let last = state.lastReminders[key] else { return true }
            return last.addingTimeInterval(Self.repeatInterval) <= now
        }
    }

    public func record(_ reminded: [AttentionItem], report: StatusReport, state: inout AppState, now: Date) {
        let active = Set(report.items.compactMap(key))
        state.lastReminders = state.lastReminders.filter { active.contains($0.key) }
        for key in reminded.compactMap(key) {
            state.lastReminders[key] = now
        }
    }

    private func key(for item: AttentionItem) -> String? {
        switch item {
        case let .manualExportDue(sourceId): "manual:\(sourceId.uuidString)"
        case let .connectDestination(destinationId): "connect:\(destinationId.uuidString)"
        default: nil
        }
    }
}
