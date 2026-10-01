import BackupCore
import Testing
@testable import BackupEverything

struct RetentionPlanTests {
    private func rules(_ daily: Int, _ weekly: Int, _ monthly: Int, _ yearly: Int) -> RetentionRules {
        RetentionRules(daily: daily, weekly: weekly, monthly: monthly, yearly: yearly)
    }

    private func sentences(_ rules: RetentionRules) -> [String] {
        RetentionPlan.stages(rules).filter(\.isKept).map { "\($0.prefix) \($0.count) \($0.unitName) — \($0.effect)" }
    }

    @Test func stagesTellWhatHappensToACopyAsItAges() {
        #expect(sentences(.standard) == [
            "First 7 days — every copy is kept",
            "Then up to 4 weeks — one per week is kept",
            "Then up to 12 months — one per month is kept",
        ])
        #expect(sentences(rules(7, 4, 12, 5)).last == "Then up to 5 years — one per year is kept")
    }

    @Test func storyStartsFromTheFirstStageThatKeepsCopies() {
        #expect(sentences(rules(0, 4, 6, 0)) == [
            "First 4 weeks — one per week is kept",
            "Then up to 6 months — one per month is kept",
        ])
        #expect(sentences(rules(0, 0, 0, 2)) == ["First 2 years — one per year is kept"])
    }

    @Test func wordsAgreeWithTheNumber() {
        #expect(sentences(rules(1, 1, 1, 1)) == [
            "First 1 day — every copy is kept",
            "Then up to 1 week — one per week is kept",
            "Then up to 1 month — one per month is kept",
            "Then up to 1 year — one per year is kept",
        ])
        #expect(sentences(rules(0, 1, 0, 0)) == ["First 1 week — one per week is kept"])
        #expect(sentences(rules(3, 21, 2, 11)) == [
            "First 3 days — every copy is kept",
            "Then up to 21 weeks — one per week is kept",
            "Then up to 2 months — one per month is kept",
            "Then up to 11 years — one per year is kept",
        ])
    }

    @Test func skippedStagesStayInPlaceSoTheyCanBeTurnedOn() {
        let stages = RetentionPlan.stages(rules(7, 0, 12, 0))
        #expect(stages.map(\.unit) == [.day, .week, .month, .year])
        #expect(stages.map(\.isKept) == [true, false, true, false])
        #expect(stages[1].prefix == "—")
        #expect(stages[1].unitName == "weeks")
        #expect(stages[1].effect == "not used")
        #expect(RetentionPlan.stages(rules(0, 4, 0, 0))[0].unitName == "days")
    }

    @Test func summaryNamesHowFarBackCopiesGo() {
        #expect(RetentionPlan.summary(.standard) == "up to 12 months")
        #expect(RetentionPlan.summary(rules(7, 0, 0, 0)) == "up to 7 days")
        #expect(RetentionPlan.summary(rules(0, 1, 0, 0)) == "up to 1 week")
        #expect(RetentionPlan.summary(rules(7, 4, 12, 5)) == "up to 5 years")
        #expect(RetentionPlan.summary(rules(0, 0, 0, 0)) == "only the latest copy")
    }
}
