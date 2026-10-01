import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct NextBackupTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func source(_ schedule: Schedule, enabled: Bool = true) -> Source {
        Source(name: "Obsidian", slug: "obsidian", steps: [.folder("~/Obsidian", excludes: [])], schedule: schedule, enabled: enabled, createdAt: now)
    }

    @Test func futureIsShortAndCoarse() {
        #expect(Texts.until(now.addingTimeInterval(20), now: now) == "now")
        #expect(Texts.until(now.addingTimeInterval(5 * 60), now: now) == "in 5 min")
        #expect(Texts.until(now.addingTimeInterval(17 * 3600), now: now) == "in 17 h")
        #expect(Texts.until(now.addingTimeInterval(3 * 86_400), now: now) == "in 3 d")
        #expect(Texts.until(now.addingTimeInterval(90 * 86_400), now: now) == "in 3 mo")
        #expect(Texts.until(now.addingTimeInterval(80 * 60), now: now) == "in 2 h")
        #expect(Texts.until(now.addingTimeInterval(61), now: now) == "in 2 min")
        #expect(Texts.until(now.addingTimeInterval(59 * 60 + 30), now: now) == "in 1 h")
        #expect(Texts.until(now.addingTimeInterval(6 * 86_400 + 3600), now: now) == "in 7 d")
    }

    @Test func nextBackupSaysWhenOrWhy() {
        #expect(NextBackup.note(source(.daily), nextDue: now.addingTimeInterval(17 * 3600), isWaiting: false, now: now) == "in 17 h")
        #expect(NextBackup.note(source(.daily), nextDue: now.addingTimeInterval(-60), isWaiting: false, now: now) == "due")
        #expect(NextBackup.note(source(.manual), nextDue: nil, isWaiting: false, now: now) == "manual")
        #expect(NextBackup.note(source(.manual), nextDue: nil, isWaiting: true, now: now) == "waiting")
        #expect(NextBackup.note(source(.daily, enabled: false), nextDue: nil, isWaiting: false, now: now) == nil)
    }

    @Test func settingsShowTheExactMoment() {
        let due = now.addingTimeInterval(17 * 3600)
        #expect(NextBackup.detail(source(.daily), nextDue: due, isWaiting: false, now: now) == Texts.dateTime(due))
        #expect(NextBackup.detail(source(.daily), nextDue: now.addingTimeInterval(-60), isWaiting: false, now: now) == "due now")
        #expect(NextBackup.detail(source(.manual), nextDue: nil, isWaiting: false, now: now) == "only with the “Run” button")
        #expect(NextBackup.detail(source(.manual), nextDue: nil, isWaiting: true, now: now) == "waiting for a file or device — starts on its own")
        #expect(NextBackup.detail(source(.daily, enabled: false), nextDue: nil, isWaiting: false, now: now) == "source is disabled")
    }
}
