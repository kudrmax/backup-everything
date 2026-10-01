import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct OverviewOrderTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func source(_ name: String, enabled: Bool = true) -> Source {
        var source = Source(name: name, slug: name.lowercased(), steps: [.folder("/\(name)")], schedule: .daily, destinationIds: [], createdAt: now)
        source.enabled = enabled
        return source
    }

    @Test func manualOrderKeepsTheOrderFromSettings() {
        let sources = [source("A"), source("B"), source("C")]
        let sorted = OverviewOrder.manual.sorted(sources) { _ in now }
        #expect(sorted.map(\.name) == ["A", "B", "C"])
    }

    @Test func soonestBackupComesFirstAndOverdueBeforeEverything() {
        let a = source("A"), b = source("B"), c = source("C")
        let due = [a.id: now.addingTimeInterval(3600), b.id: now.addingTimeInterval(-60), c.id: now.addingTimeInterval(60)]
        let sorted = OverviewOrder.nextBackup.sorted([a, b, c]) { due[$0.id] }
        #expect(sorted.map(\.name) == ["B", "C", "A"])
    }

    @Test func sourcesWithoutScheduleAndDisabledOnesGoLastInSettingsOrder() {
        let manualOnly = source("Manual"), off = source("Off", enabled: false), soon = source("Soon"), later = source("Later")
        let due = [soon.id: now, later.id: now.addingTimeInterval(60), off.id: now.addingTimeInterval(-600)]
        let sorted = OverviewOrder.nextBackup.sorted([manualOnly, off, later, soon]) { due[$0.id] }
        #expect(sorted.map(\.name) == ["Soon", "Later", "Manual", "Off"])
    }
}
