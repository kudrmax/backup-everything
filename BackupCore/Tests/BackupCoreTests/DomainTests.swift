import Foundation
import Testing
@testable import BackupCore

struct DomainTests {
    @Test func slugKeepsLettersOfAnyScriptAndCollapsesSeparators() {
        #expect(Slug.make(from: "Настройки Backup  Everything!", existing: []) == "настройки-backup-everything")
    }

    @Test func slugAvoidsCollisions() {
        #expect(Slug.make(from: "GitHub", existing: ["github", "github-2"]) == "github-3")
    }

    @Test func slugFallsBackWhenNameHasNoLetters() {
        #expect(Slug.make(from: "!!!", existing: []) == "source")
    }

    @Test func snapshotNameRoundTrips() {
        let date = Fixtures.date("2026-09-28 14:30:05")
        let name = Fixtures.naming.name(for: date)
        #expect(name == "2026-09-28_143005")
        #expect(Fixtures.naming.date(from: name) == date)
    }

    @Test(arguments: ["Photos", "2026-09-28", "2026-13-40_000000", "2026-09-28_143005 copy"])
    func snapshotNamingRejectsForeignNames(name: String) {
        #expect(Fixtures.naming.date(from: name) == nil)
    }

    @Test func scheduleComputesNextDue() {
        let start = Fixtures.date("2026-01-31 10:00:00")
        #expect(Schedule.daily.nextDue(after: start, calendar: Fixtures.calendar) == Fixtures.date("2026-02-01 10:00:00"))
        #expect(Schedule.weekly.nextDue(after: start, calendar: Fixtures.calendar) == Fixtures.date("2026-02-07 10:00:00"))
        #expect(Schedule.monthly.nextDue(after: start, calendar: Fixtures.calendar) == Fixtures.date("2026-02-28 10:00:00"))
        #expect(Schedule.manual.nextDue(after: start, calendar: Fixtures.calendar) == nil)
    }

    @Test func configRoundTripsThroughJSON() throws {
        let disk = Destination(name: "HDD", kind: .localFolder(path: "/Volumes/HDD/Backups"), expectedEvery: .days(30))
        let cloud = Destination(name: "Cloud", kind: .rclone(remote: "gdrive", path: "backups"))
        let config = Config(
            sources: [
                Fixtures.source(name: "Obsidian", kind: .folder(path: "~/Obsidian", excludes: [".trash"]), destinations: [disk, cloud]),
                Fixtures.source(name: "GitHub", kind: .command(command: "gh repo list", timeoutSeconds: 60), schedule: .weekly),
                Fixtures.source(
                    name: "Photos",
                    kind: .manualExport(watchPath: "~/Downloads", filePattern: "takeout-*.zip", fileMode: .multiple, removeOriginal: true),
                    schedule: .monthly
                ),
            ],
            destinations: [disk, cloud]
        )
        let data = try JSONCoding.encoder().encode(config)
        #expect(try JSONCoding.decoder().decode(Config.self, from: data) == config)
    }

    @Test func sourceKindHasReadableJSONShape() throws {
        let json = #"{"folder":{"path":"~/Obsidian","excludes":[".trash"]}}"#
        let kind = try JSONCoding.decoder().decode(SourceKind.self, from: Data(json.utf8))
        #expect(kind == .folder(path: "~/Obsidian", excludes: [".trash"]))
    }
}
