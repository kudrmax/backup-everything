import Foundation
import Testing
@testable import BackupCore

/// Reproductions of bugs found in persistence and configuration. Each test describes the expected behaviour and fails today.
struct FoundBugsPersistenceTests {
    private let editor = ConfigEditor()

    @Test func newSourceWithTheNameOfADeletedOneDoesNotTakeOverAndPruneItsCopies() async throws {
        let temp = try TempDirectory()
        defer { try? FileManager.default.trashItem(at: temp.url, resultingItemURL: nil) }
        let store = Store(dataDirectory: temp.path("data"))
        let time = FakeTimeSource(Fixtures.date("2026-09-01 10:00:00"))
        try temp.file("notes/old.txt", "old notes")
        try temp.file("photos/new.jpg", "new photos")
        try temp.directory("backups")
        let disk = Fixtures.localDestination("Disk", at: temp.path("backups"))
        let onlyNewest = RetentionRules(daily: 0, weekly: 0, monthly: 0, yearly: 0)
        let coordinator = CoreAssembly.makeCoordinator(
            dataDirectory: temp.path("data"),
            workDirectory: temp.path("work"),
            timeZone: Fixtures.utc,
            time: time
        )

        var config = Config(destinations: [disk])
        var old = editor.makeSource(name: "Archive", steps: [.folder(temp.path("notes").path)], retention: onlyNewest, now: time.now, in: config)
        old.destinationIds = [disk.id]
        editor.save(old, in: &config)
        try store.saveConfig(config)
        _ = try await coordinator.tick()
        #expect(temp.exists("backups/archive/2026-09-01_100000/old.txt"))

        editor.removeSource(old.id, from: &config)
        time.advance(86_400)
        var replacement = editor.makeSource(name: "Archive", steps: [.folder(temp.path("photos").path)], retention: onlyNewest, now: time.now, in: config)
        replacement.destinationIds = [disk.id]
        editor.save(replacement, in: &config)
        try store.saveConfig(config)
        _ = try await coordinator.tick()

        #expect(temp.exists("backups/archive/2026-09-01_100000/old.txt"), "the only copy of the deleted source was pruned by an unrelated new source")
        #expect(config.sources.first?.slug != old.slug, "the new source writes into the folder of the deleted one")
    }

    @Test func masksThatMatchTheSameFileAreReportedAsOverlapping() {
        func manual(_ name: String, _ pattern: String) -> Source {
            Fixtures.source(name: name, steps: [.file(pattern, in: "~/Downloads", mode: .single, removeOriginal: true)])
        }
        let contacts = manual("Contacts", "*.vcf")
        let work = manual("Work contacts", "Work*")
        let passwords = manual("Passwords", "Passwords*.csv")
        let finance = manual("Finance", "*-export.csv")
        let config = Config(sources: [contacts, work, passwords, finance])

        // "Work.vcf" is picked up by both sources; "Passwords-export.csv" too.
        #expect(GlobPattern("*.vcf").matches("Work.vcf") && GlobPattern("Work*").matches("Work.vcf"))
        #expect(GlobPattern("Passwords*.csv").matches("Passwords-export.csv") && GlobPattern("*-export.csv").matches("Passwords-export.csv"))
        #expect(editor.maskConflicts(for: contacts, in: config).map(\.name) == ["Work contacts"])
        #expect(editor.maskConflicts(for: passwords, in: config).map(\.name) == ["Finance"])
    }
}
