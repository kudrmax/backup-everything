import Foundation
import Testing
@testable import BackupCore

struct ExcessCopiesTests {
    private let calculator = ExcessCalculator(retention: RetentionPolicy(timeZone: Fixtures.utc))
    private let destination = Fixtures.localDestination("HDD", at: URL(fileURLWithPath: "/Volumes/HDD/Backups"))

    @Test func listsCopiesBeyondTheRuleOldestFirst() throws {
        var source = Fixtures.source(destinations: [destination])
        source.retention = RetentionRules(daily: 2, weekly: 0, monthly: 0, yearly: 0)
        let copies = ["2026-10-01 10:00:00", "2026-10-02 10:00:00", "2026-10-03 10:00:00"].map(Fixtures.snapshot)
        let excess = try calculator.excess(of: source, on: destination, copies: copies, folder: { URL(fileURLWithPath: "/Volumes/HDD/Backups/obsidian/\($0.name)") }, asOf: nil)
        #expect(excess.items.map(\.snapshot) == [Fixtures.snapshot("2026-10-01 10:00:00")])
        #expect(excess.sourceId == source.id && excess.destinationId == destination.id)
    }

    @Test func commandHandsTheFoldersBackAndTrashesThem() {
        let item = ExcessCopies.Item(snapshot: Fixtures.snapshot("2026-10-01 10:00:00"), folder: URL(fileURLWithPath: "/Volumes/HDD/Backups/obsidian/2026-10-01_100000"), bytes: 0)
        #expect(ExcessCopies.command(for: [item], user: "max") == "sudo chown -R 'max' '/Volumes/HDD/Backups/obsidian/2026-10-01_100000' && trash '/Volumes/HDD/Backups/obsidian/2026-10-01_100000'")
    }

    @Test func commandQuotesQuotesAndDollarsInPaths() {
        let item = ExcessCopies.Item(snapshot: Fixtures.snapshot("2026-10-01 10:00:00"), folder: URL(fileURLWithPath: "/Volumes/Max's $HDD/obsidian/2026-10-01_100000"), bytes: 0)
        let folder = "'/Volumes/Max'\\''s $HDD/obsidian/2026-10-01_100000'"
        #expect(ExcessCopies.command(for: [item], user: "o'neil") == "sudo chown -R 'o'\\''neil' \(folder) && trash \(folder)")
    }

    @Test func folderErrorIsNotSwallowed() {
        var source = Fixtures.source(destinations: [destination])
        source.retention = RetentionRules(daily: 1, weekly: 0, monthly: 0, yearly: 0)
        let copies = ["2026-10-01 10:00:00", "2026-10-02 10:00:00"].map(Fixtures.snapshot)
        struct Broken: Error {}
        #expect(throws: Broken.self) {
            try calculator.excess(of: source, on: destination, copies: copies, folder: { _ in throw Broken() }, asOf: nil)
        }
    }

    @Test func newestCopyIsNeverListed() throws {
        var source = Fixtures.source(destinations: [destination])
        source.retention = RetentionRules(daily: 0, weekly: 0, monthly: 0, yearly: 0)
        let excess = try calculator.excess(of: source, on: destination, copies: [Fixtures.snapshot("2026-10-01 10:00:00")], folder: { URL(fileURLWithPath: "/x/\($0.name)") }, asOf: nil)
        #expect(excess.items.isEmpty)
    }
}
