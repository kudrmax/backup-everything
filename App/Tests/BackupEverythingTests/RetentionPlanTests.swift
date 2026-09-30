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
            "Первые 7 дней — хранятся все копии",
            "Потом до 4 недель — остаётся одна в неделю",
            "Потом до 12 месяцев — остаётся одна в месяц",
        ])
        #expect(sentences(rules(7, 4, 12, 5)).last == "Потом до 5 лет — остаётся одна в год")
    }

    @Test func storyStartsFromTheFirstStageThatKeepsCopies() {
        #expect(sentences(rules(0, 4, 6, 0)) == [
            "Первые 4 недели — остаётся одна в неделю",
            "Потом до 6 месяцев — остаётся одна в месяц",
        ])
        #expect(sentences(rules(0, 0, 0, 2)) == ["Первые 2 года — остаётся одна в год"])
    }

    @Test func wordsAgreeWithTheNumber() {
        #expect(sentences(rules(1, 1, 1, 1)) == [
            "Первый 1 день — хранятся все копии",
            "Потом до 1 недели — остаётся одна в неделю",
            "Потом до 1 месяца — остаётся одна в месяц",
            "Потом до 1 года — остаётся одна в год",
        ])
        #expect(sentences(rules(0, 1, 0, 0)) == ["Первую 1 неделю — остаётся одна в неделю"])
        #expect(sentences(rules(3, 21, 2, 11)) == [
            "Первые 3 дня — хранятся все копии",
            "Потом до 21 недели — остаётся одна в неделю",
            "Потом до 2 месяцев — остаётся одна в месяц",
            "Потом до 11 лет — остаётся одна в год",
        ])
    }

    @Test func skippedStagesStayInPlaceSoTheyCanBeTurnedOn() {
        let stages = RetentionPlan.stages(rules(7, 0, 12, 0))
        #expect(stages.map(\.unit) == [.day, .week, .month, .year])
        #expect(stages.map(\.isKept) == [true, false, true, false])
        #expect(stages[1].prefix == "—")
        #expect(stages[1].unitName == "недель")
        #expect(stages[1].effect == "не используется")
        #expect(RetentionPlan.stages(rules(0, 4, 0, 0))[0].unitName == "дней")
    }

    @Test func summaryNamesHowFarBackCopiesGo() {
        #expect(RetentionPlan.summary(.standard) == "до 12 месяцев")
        #expect(RetentionPlan.summary(rules(7, 0, 0, 0)) == "до 7 дней")
        #expect(RetentionPlan.summary(rules(0, 1, 0, 0)) == "до 1 недели")
        #expect(RetentionPlan.summary(rules(7, 4, 12, 5)) == "до 5 лет")
        #expect(RetentionPlan.summary(rules(0, 0, 0, 0)) == "только последнюю копию")
    }
}
