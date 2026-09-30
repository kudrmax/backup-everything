import Foundation
import Testing
@testable import BackupCore

struct ReminderPlannerTests {
    private let planner = ReminderPlanner()
    private let now = Fixtures.date("2026-09-28 10:00:00")
    private let sourceId = UUID()
    private let diskId = UUID()

    @Test func remindsOnceADayOnlyAboutActionableItems() {
        let report = StatusReport(items: [
            .manualExportDue(sourceId: sourceId),
            .connectDestination(destinationId: diskId),
            .runFailed(sourceId: sourceId, message: "quota"),
            .destinationUnavailable(destinationId: diskId),
        ])
        var state = AppState()
        let first = planner.dueReminders(in: report, state: state, now: now)
        #expect(first == [.manualExportDue(sourceId: sourceId), .connectDestination(destinationId: diskId)])

        planner.record(first, report: report, state: &state, now: now)
        #expect(planner.dueReminders(in: report, state: state, now: now.addingTimeInterval(3600)).isEmpty)
        #expect(planner.dueReminders(in: report, state: state, now: now.addingTimeInterval(86_400)) == first)
    }

    @Test func resolvedReminderIsForgottenSoItFiresImmediatelyNextTime() {
        let due = StatusReport(items: [.manualExportDue(sourceId: sourceId)])
        var state = AppState()
        planner.record(due.items, report: due, state: &state, now: now)

        planner.record([], report: StatusReport(items: []), state: &state, now: now.addingTimeInterval(60))
        #expect(state.lastReminders.isEmpty)
        #expect(planner.dueReminders(in: due, state: state, now: now.addingTimeInterval(120)) == due.items)
    }
}
