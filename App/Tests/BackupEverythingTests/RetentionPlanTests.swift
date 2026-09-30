import BackupCore
import Testing
@testable import BackupEverything

struct RetentionPlanTests {
    private func rules(_ daily: Int, _ weekly: Int, _ monthly: Int, _ yearly: Int) -> RetentionRules {
        RetentionRules(daily: daily, weekly: weekly, monthly: monthly, yearly: yearly)
    }

    @Test func standardRulesAreTheYearPreset() {
        #expect(RetentionPreset.matching(.standard) == .year)
        #expect(RetentionPreset.matching(rules(7, 0, 0, 0)) == .week)
        #expect(RetentionPreset.matching(rules(7, 4, 12, 5)) == .fiveYears)
        #expect(RetentionPreset.matching(rules(0, 8, 12, 0)) == nil)
    }

    @Test func presetsShorterThanTheScheduleAreNotOffered() {
        #expect(RetentionPreset.offered(for: .daily) == [.week, .month, .year, .fiveYears])
        #expect(RetentionPreset.offered(for: .manual) == [.week, .month, .year, .fiveYears])
        #expect(RetentionPreset.offered(for: .weekly) == [.month, .year, .fiveYears])
        #expect(RetentionPreset.offered(for: .monthly) == [.year, .fiveYears])
    }

    @Test func summaryNamesHowFarBackCopiesGo() {
        #expect(RetentionPlan.summary(.standard) == "за год")
        #expect(RetentionPlan.summary(rules(7, 0, 0, 0)) == "за неделю")
        #expect(RetentionPlan.summary(rules(0, 4, 6, 0)) == "за 6 месяцев")
        #expect(RetentionPlan.summary(rules(3, 0, 0, 0)) == "за 3 дня")
        #expect(RetentionPlan.summary(rules(0, 1, 0, 0)) == "за 1 неделю")
        #expect(RetentionPlan.summary(rules(0, 0, 0, 2)) == "за 2 года")
        #expect(RetentionPlan.summary(rules(0, 0, 0, 0)) == "только последнюю копию")
    }

    @Test func stepsSkipEmptyRulesAndSayHowOftenACopyIsKept() {
        #expect(RetentionPlan.steps(rules(7, 0, 12, 0)).map(\.label) == ["7 дней — каждый день", "12 месяцев — раз в месяц"])
        #expect(RetentionPlan.steps(rules(0, 1, 0, 5)).map(\.label) == ["1 неделя — раз в неделю", "5 лет — раз в год"])
        #expect(RetentionPlan.steps(rules(0, 0, 0, 0)).isEmpty)
    }

    @Test func explanationSaysWhatYouCanGoBackTo() {
        #expect(RetentionPlan.explanation(.standard, schedule: .daily)
            == "Можно вернуться к любому дню за 7 дней, к любой неделе за 4 недели и к любому месяцу за 12 месяцев. Всё, что старше, удаляется само.")
        #expect(RetentionPlan.explanation(rules(7, 0, 0, 0), schedule: .daily)
            == "Можно вернуться к любому дню за 7 дней. Всё, что старше, удаляется само.")
    }

    @Test func explanationLeavesOutStepsFinerThanTheSchedule() {
        #expect(RetentionPlan.explanation(.standard, schedule: .weekly)
            == "Можно вернуться к любой неделе за 4 недели и к любому месяцу за 12 месяцев. Всё, что старше, удаляется само.")
        #expect(RetentionPlan.explanation(rules(7, 4, 12, 5), schedule: .monthly)
            == "Можно вернуться к любому месяцу за 12 месяцев и к любому году за 5 лет. Всё, что старше, удаляется само.")
        #expect(RetentionPlan.explanation(rules(7, 0, 0, 0), schedule: .monthly)
            == "Хранятся 7 последних копий. Всё, что старше, удаляется само.")
    }

    @Test func explanationOfEmptyRules() {
        #expect(RetentionPlan.explanation(rules(0, 0, 0, 0), schedule: .daily) == "Хранится только самая свежая копия.")
    }
}
