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

    private func rules(daily: Int = 0, weekly: Int = 0, monthly: Int = 0, yearly: Int = 0) -> RetentionRules {
        RetentionRules(daily: daily, weekly: weekly, monthly: monthly, yearly: yearly)
    }

    private func kept(_ texts: [String], _ rules: RetentionRules, in policy: RetentionPolicy? = nil) -> [String] {
        (policy ?? self.policy).snapshotsToKeep(texts.map(Fixtures.snapshot), rules: rules).map(\.date).sorted().map(Self.utcText)
    }

    private static func utcText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Fixtures.utc
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    @Test func weekStartsOnMonday() {
        let sundayAndMonday = ["2026-09-27 12:00:00", "2026-09-28 12:00:00"]
        #expect(kept(sundayAndMonday, rules(weekly: 2)) == sundayAndMonday)
        let mondayAndSunday = ["2026-09-21 12:00:00", "2026-09-27 12:00:00"]
        #expect(kept(mondayAndSunday, rules(weekly: 1)) == ["2026-09-27 12:00:00"])
    }

    @Test func fiftyThirdIsoWeekCollapsesAcrossNewYear() {
        let snapshots = ["2026-12-28 12:00:00", "2027-01-03 12:00:00", "2027-01-04 12:00:00"]
        #expect(kept(snapshots, rules(weekly: 2)) == ["2027-01-03 12:00:00", "2027-01-04 12:00:00"])
        #expect(kept(Array(snapshots.prefix(2)), rules(weekly: 1)) == ["2027-01-03 12:00:00"])
    }

    @Test func monthBoundaryIsExactToTheSecond() {
        let snapshots = ["2026-01-31 23:59:59", "2026-02-01 00:00:00"]
        #expect(kept(snapshots, rules(monthly: 2)) == snapshots)
        #expect(kept(snapshots, rules(monthly: 1)) == ["2026-02-01 00:00:00"])
        #expect(kept(snapshots, rules(daily: 2)) == snapshots)
    }

    @Test func yearBoundaryAndLeapDay() {
        let snapshots = ["2027-12-31 23:59:59", "2028-02-29 12:00:00", "2028-03-01 12:00:00"]
        #expect(kept(snapshots, rules(yearly: 2)) == ["2027-12-31 23:59:59", "2028-03-01 12:00:00"])
        #expect(kept(snapshots, rules(daily: 3)) == snapshots)
    }

    @Test func daysAreCountedInTheLocalTimeZone() {
        let moscow = RetentionPolicy(timeZone: TimeZone(identifier: "Europe/Moscow")!)
        let lateEveningAndAfterMidnight = ["2026-09-27 20:30:00", "2026-09-27 21:30:00"]
        #expect(kept(lateEveningAndAfterMidnight, rules(daily: 2)) == ["2026-09-27 21:30:00"])
        #expect(kept(lateEveningAndAfterMidnight, rules(daily: 2), in: moscow) == lateEveningAndAfterMidnight)
    }

    @Test func monthsAndYearsAreCountedInTheLocalTimeZone() {
        let moscow = RetentionPolicy(timeZone: TimeZone(identifier: "Europe/Moscow")!)
        let newYearsEve = ["2026-12-31 20:00:00", "2026-12-31 22:00:00"]
        #expect(kept(newYearsEve, rules(yearly: 2)) == ["2026-12-31 22:00:00"])
        #expect(kept(newYearsEve, rules(yearly: 2), in: moscow) == newYearsEve)
        #expect(kept(newYearsEve, rules(monthly: 2), in: moscow) == newYearsEve)
    }

    @Test func daylightSavingDaysAreStillOneDay() {
        let berlin = RetentionPolicy(timeZone: TimeZone(identifier: "Europe/Berlin")!)
        let springForward = ["2026-03-28 23:30:00", "2026-03-29 21:30:00", "2026-03-29 22:30:00"]
        #expect(kept(springForward, rules(daily: 2), in: berlin) == ["2026-03-29 21:30:00", "2026-03-29 22:30:00"])
        let fallBack = ["2026-10-24 22:30:00", "2026-10-25 00:30:00", "2026-10-25 01:30:00", "2026-10-25 22:59:59"]
        #expect(kept(fallBack, rules(daily: 1), in: berlin) == ["2026-10-25 22:59:59"])
        #expect(kept(fallBack + ["2026-10-25 23:00:00"], rules(daily: 2), in: berlin) == ["2026-10-25 22:59:59", "2026-10-25 23:00:00"])
    }

    @Test func oneOfEachTierKeepsOnlyTheNewest() {
        let snapshots = dailySnapshots(from: "2025-08-01 12:00:00", days: 400)
        let kept = policy.snapshotsToKeep(snapshots, rules: rules(daily: 1, weekly: 1, monthly: 1, yearly: 1))
        #expect(kept == [snapshots.last!])
        #expect(policy.snapshotsToDelete(snapshots, rules: rules(daily: 1, weekly: 1, monthly: 1, yearly: 1)).count == 399)
    }

    @Test func negativeNumbersKeepNothingBeyondTheNewest() {
        let snapshots = dailySnapshots(from: "2026-09-01 12:00:00", days: 3)
        #expect(policy.snapshotsToKeep(snapshots, rules: rules(daily: -1, weekly: -5, monthly: -1, yearly: -1)) == [snapshots[2]])
    }

    @Test func copiesWithTheSameTimeCountAsOneAndOneOfThemStays() {
        let date = Fixtures.date("2026-09-28 12:00:00")
        let twins = [Snapshot(name: "2026-09-28_120000", date: date), Snapshot(name: "2026-09-28_150000", date: date)]
        for order in [twins, twins.reversed()] {
            let keep = policy.snapshotsToKeep(order, rules: rules(daily: 7))
            let delete = policy.snapshotsToDelete(order, rules: rules(daily: 7))
            #expect(keep.count == 1)
            #expect(delete.count == 1)
            #expect(keep.union(delete) == Set(twins))
        }
    }

    @Test func keptAndDeletedSplitTheCopiesRegardlessOfOrder() {
        let snapshots = dailySnapshots(from: "2025-06-15 09:00:00", days: 500)
        let keep = policy.snapshotsToKeep(snapshots, rules: .standard)
        let delete = policy.snapshotsToDelete(snapshots.reversed(), rules: .standard)
        #expect(keep.isDisjoint(with: delete))
        #expect(keep.union(delete) == Set(snapshots))
        #expect(delete == delete.sorted { $0.date < $1.date })
        #expect(policy.snapshotsToKeep(snapshots.shuffled(), rules: .standard) == keep)
        #expect(keep.count == 7 + 4 + 12 - 3)
    }

    @Test func gapsBetweenMonthsDoNotConsumeMonthlyQuota() {
        let snapshots = ["2025-01-10 12:00:00", "2025-06-10 12:00:00", "2026-09-10 12:00:00"]
        #expect(kept(snapshots, rules(monthly: 3)) == snapshots)
        #expect(kept(snapshots, rules(monthly: 2)) == ["2025-06-10 12:00:00", "2026-09-10 12:00:00"])
    }
}
