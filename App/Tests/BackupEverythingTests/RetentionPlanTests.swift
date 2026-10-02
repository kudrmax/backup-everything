import BackupCore
import Testing
@testable import BackupEverything

struct RetentionPlanTests {
    private func rules(_ daily: Int, _ weekly: Int, _ monthly: Int, _ yearly: Int) -> RetentionRules {
        RetentionRules(daily: daily, weekly: weekly, monthly: monthly, yearly: yearly)
    }

    private func sentences(_ rules: RetentionRules) -> [String] {
        RetentionPlan.stages(rules).filter(\.isKept).map(\.sentence)
    }

    @Test func eachStageSaysHowManyPeriodsWithABackupKeepACopy() {
        #expect(sentences(rules(7, 4, 12, 5)) == [
            "Keep one copy per day for the last 7 days you backed up",
            "Keep one copy per week for the last 4 weeks you backed up",
            "Keep one copy per month for the last 12 months you backed up",
            "Keep one copy per year for the last 5 years you backed up",
        ])
    }

    @Test func wordsAgreeWithTheNumber() {
        #expect(sentences(rules(1, 1, 1, 1)) == [
            "Keep one copy per day for the last 1 day you backed up",
            "Keep one copy per week for the last 1 week you backed up",
            "Keep one copy per month for the last 1 month you backed up",
            "Keep one copy per year for the last 1 year you backed up",
        ])
    }

    @Test func skippedStagesStayInPlaceSoTheyCanBeTurnedOn() {
        let stages = RetentionPlan.stages(rules(7, 0, 12, 0))
        #expect(stages.map(\.unit) == [.day, .week, .month, .year])
        #expect(stages.map(\.isKept) == [true, false, true, false])
        #expect(stages[1].tail == "weeks you backed up")
    }

    @Test func summaryNamesTheLongestStage() {
        #expect(RetentionPlan.summary(.standard) == "last 12 months you backed up")
        #expect(RetentionPlan.summary(rules(7, 0, 0, 0)) == "last 7 days you backed up")
        #expect(RetentionPlan.summary(rules(0, 1, 0, 0)) == "last 1 week you backed up")
        #expect(RetentionPlan.summary(rules(7, 4, 12, 5)) == "last 5 years you backed up")
        #expect(RetentionPlan.summary(rules(0, 0, 0, 0)) == "only the newest copy")
    }
}
