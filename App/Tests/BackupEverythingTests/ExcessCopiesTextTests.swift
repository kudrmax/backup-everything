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

    @Test func unfinishedAttemptsAreCountedApart() {
        let hdd = Destination(name: "HDD", kind: .localFolder(path: "/Volumes/HDD/Backups"))
        let source = Source(name: "Obsidian", slug: "obsidian", steps: [.folder("/x")], schedule: .daily, destinationIds: [hdd.id], createdAt: Date())
        let config = Config(sources: [source], destinations: [hdd])
        let snapshot = Snapshot(name: "2026-10-01_100000", date: Date())
        let copy = ExcessCopies.Item(snapshot: snapshot, folder: URL(fileURLWithPath: "/x/a"), bytes: 1_000_000_000)
        let attempt = ExcessCopies.Item(snapshot: snapshot, folder: URL(fileURLWithPath: "/x/b"), bytes: 1_000_000_000, isUnfinished: true)
        let mixed = ExcessCopies(sourceId: source.id, destinationId: hdd.id, items: [copy, copy, attempt], asOf: nil)
        #expect(ExcessCopiesText.title(mixed, config: config) == "Obsidian on HDD: 2 copies and 1 unfinished attempt, up to 3 GB")
        #expect(ExcessCopiesText.summary([mixed], config: config) == "2 copies beyond the rules and 1 unfinished attempt, up to 3 GB")
        let attempts = ExcessCopies(sourceId: source.id, destinationId: hdd.id, items: [attempt, attempt], asOf: nil)
        #expect(ExcessCopiesText.title(attempts, config: config) == "Obsidian on HDD: 2 unfinished attempts, up to 2 GB")
        #expect(ExcessCopiesText.summary([attempts], config: config) == "2 unfinished attempts, up to 2 GB")
    }

    /// An unfinished attempt may be the folder rsync is writing right now: no removal command while a backup runs.
    @Test func noCommandWhileABackupRuns() {
        let item = ExcessCopies.Item(snapshot: Snapshot(name: "2026-10-01_100000", date: Date()), folder: URL(fileURLWithPath: "/x/a"), bytes: 0, isUnfinished: true)
        let excess = ExcessCopies(sourceId: UUID(), destinationId: UUID(), items: [item], asOf: nil)
        #expect(ExcessCopiesText.command(for: excess, user: "max", backupRunning: true) == nil)
        #expect(ExcessCopiesText.command(for: excess, user: "max", backupRunning: false) == "sudo chown -R 'max' '/x/a' && trash '/x/a'")
        #expect(ExcessCopiesText.whileRunning == "Commands appear when no backup is running.")
    }
}
