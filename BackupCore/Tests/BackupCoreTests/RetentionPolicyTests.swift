import Foundation
import Testing
@testable import BackupCore

struct RetentionPolicyTests {
    private let policy = RetentionPolicy(timeZone: Fixtures.utc)

    private func dailySnapshots(from start: String, days: Int) -> [Snapshot] {
        let first = Fixtures.date(start)
        return (0..<days).map { offset in
            let date = Fixtures.calendar.date(byAdding: .day, value: offset, to: first)!
            return Snapshot(name: Fixtures.naming.name(for: date), date: date)
        }
    }

    private func keptDays(_ snapshots: [Snapshot], _ rules: RetentionRules) -> [String] {
        policy.snapshotsToKeep(snapshots, rules: rules).map { String($0.name.prefix(10)) }.sorted()
    }

    @Test func keepsDailyWeeklyAndMonthlyTiers() {
        let snapshots = dailySnapshots(from: "2026-07-31 12:00:00", days: 60)
        #expect(keptDays(snapshots, RetentionRules(daily: 7, weekly: 4, monthly: 12, yearly: 0)) == [
            "2026-07-31", "2026-08-31", "2026-09-13", "2026-09-20",
            "2026-09-22", "2026-09-23", "2026-09-24", "2026-09-25", "2026-09-26", "2026-09-27", "2026-09-28",
        ])
    }

    @Test func gapsDoNotConsumeQuota() {
        let snapshots = ["2026-09-28 12:00:00", "2026-09-20 12:00:00", "2026-08-02 12:00:00"].map(Fixtures.snapshot)
        #expect(keptDays(snapshots, RetentionRules(daily: 3, weekly: 0, monthly: 0, yearly: 0)) == [
            "2026-08-02", "2026-09-20", "2026-09-28",
        ])
    }

    @Test func keepsNewestOfEachDay() {
        let morning = Fixtures.snapshot("2026-09-28 08:00:00")
        let evening = Fixtures.snapshot("2026-09-28 20:00:00")
        let kept = policy.snapshotsToKeep([morning, evening], rules: RetentionRules(daily: 5, weekly: 0, monthly: 0, yearly: 0))
        #expect(kept == [evening])
    }

    @Test func newestSnapshotSurvivesZeroRules() {
        let snapshots = dailySnapshots(from: "2026-09-01 12:00:00", days: 5)
        let rules = RetentionRules(daily: 0, weekly: 0, monthly: 0, yearly: 0)
        #expect(keptDays(snapshots, rules) == ["2026-09-05"])
        #expect(policy.snapshotsToDelete(snapshots, rules: rules).count == 4)
    }

    @Test func isoWeekSpansYearBoundary() {
        let snapshots = ["2026-12-31 12:00:00", "2027-01-01 12:00:00", "2027-01-04 12:00:00"].map(Fixtures.snapshot)
        #expect(keptDays(snapshots, RetentionRules(daily: 0, weekly: 2, monthly: 0, yearly: 0)) == ["2027-01-01", "2027-01-04"])
    }

    @Test func yearlyTierKeepsLastSnapshotOfEachYear() {
        let snapshots = ["2024-05-01 12:00:00", "2025-03-01 12:00:00", "2025-11-01 12:00:00", "2026-02-01 12:00:00"].map(Fixtures.snapshot)
        #expect(keptDays(snapshots, RetentionRules(daily: 0, weekly: 0, monthly: 0, yearly: 3)) == [
            "2024-05-01", "2025-11-01", "2026-02-01",
        ])
    }

    @Test func emptyAndSingleInputs() {
        #expect(policy.snapshotsToKeep([], rules: .standard).isEmpty)
        let only = Fixtures.snapshot("2026-09-28 12:00:00")
        #expect(policy.snapshotsToDelete([only], rules: .standard).isEmpty)
    }
}
