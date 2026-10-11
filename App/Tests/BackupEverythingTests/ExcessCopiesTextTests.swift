import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct ExcessCopiesTextTests {
    @Test func summaryCountsCopiesAndBytes() {
        let hdd = Destination(name: "HDD", kind: .localFolder(path: "/Volumes/HDD/Backups"))
        let source = Source(name: "Obsidian", slug: "obsidian", steps: [.folder("/x")], schedule: .daily, destinationIds: [hdd.id], createdAt: Date())
        let config = Config(sources: [source], destinations: [hdd])
        let item = ExcessCopies.Item(snapshot: Snapshot(name: "2026-10-01_100000", date: Date()), folder: URL(fileURLWithPath: "/Volumes/HDD/Backups/obsidian/2026-10-01_100000"), bytes: 1_500_000_000)
        let excess = [ExcessCopies(sourceId: source.id, destinationId: hdd.id, items: [item, item], asOf: nil)]
        #expect(ExcessCopiesText.summary(excess, config: config) == "2 copies beyond the rules, up to 3 GB")
        #expect(ExcessCopiesText.title(excess[0], config: config) == "Obsidian on HDD: 2 copies, up to 3 GB")
        #expect(ExcessCopiesText.summary([], config: config) == nil)
    }

    @Test func cachedExcessSaysWhenItWasSeen() {
        let hdd = Destination(name: "HDD", kind: .localFolder(path: "/Volumes/HDD/Backups"))
        let source = Source(name: "Obsidian", slug: "obsidian", steps: [.folder("/x")], schedule: .daily, destinationIds: [hdd.id], createdAt: Date())
        let config = Config(sources: [source], destinations: [hdd])
        let item = ExcessCopies.Item(snapshot: Snapshot(name: "2026-10-01_100000", date: Date()), folder: URL(fileURLWithPath: "/x"), bytes: 0)
        let seen = Date().addingTimeInterval(-3 * 86_400)
        #expect(ExcessCopiesText.title(ExcessCopies(sourceId: source.id, destinationId: hdd.id, items: [item], asOf: seen), config: config) == "Obsidian on HDD: 1 copy (as seen 3 days ago)")
    }
}
