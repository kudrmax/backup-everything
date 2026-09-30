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

    @Test func stepChainRoundTripsThroughReadableJSON() throws {
        let steps = [
            SourceStep(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                name: "Запросить экспорт",
                kind: .manual(instructions: "скачай манифест", watchPath: "~/Downloads", filePattern: "manifest-*.json", includeInCopy: false)
            ),
            SourceStep(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                name: "Скачать архивы",
                kind: .command(command: "echo hi", timeoutSeconds: 3600)
            ),
        ]
        let source = Fixtures.source(name: "Claude", kind: .steps(steps: steps), schedule: .monthly)
        let data = try JSONCoding.encoder().encode(source)
        #expect(try JSONCoding.decoder().decode(Source.self, from: data) == source)

        let json = #"{"steps":{"steps":[{"id":"00000000-0000-0000-0000-000000000002","name":"Скачать архивы","kind":{"command":{"command":"echo hi","timeoutSeconds":3600}}}]}}"#
        #expect(try JSONCoding.decoder().decode(SourceKind.self, from: Data(json.utf8)) == .steps(steps: [steps[1]]))
    }

    @Test func sourceKnowsWhichFilesItWaitsFor() {
        let manual = SourceStep(name: "A", kind: .manual(instructions: "", watchPath: "~/Downloads", filePattern: "manifest-*.json", includeInCopy: false))
        let command = SourceStep(name: "B", kind: .command(command: "true", timeoutSeconds: 60))
        let chain = Fixtures.source(kind: .steps(steps: [manual, command]))
        #expect(chain.isStepChain)
        #expect(chain.deliversFromPending)
        #expect(chain.steps.map(\.isManual) == [true, false])
        #expect(chain.watchedFiles == [WatchedFile(watchPath: "~/Downloads", filePattern: "manifest-*.json")])

        let export = Fixtures.source(kind: .manualExport(watchPath: "~/Downloads", filePattern: "takeout-*.zip", fileMode: .multiple, removeOriginal: true))
        #expect(!export.isStepChain)
        #expect(export.deliversFromPending)
        #expect(export.watchedFiles == [WatchedFile(watchPath: "~/Downloads", filePattern: "takeout-*.zip")])

        let folder = Fixtures.source()
        #expect(!folder.deliversFromPending)
        #expect(folder.steps.isEmpty)
        #expect(folder.watchedFiles.isEmpty)
    }

    @Test func stateSavedBeforeChainsStillLoadsAndChainRoundTrips() throws {
        let legacy = Data(#"{"lastRun":"2026-09-28T10:00:00Z"}"#.utf8)
        #expect(try JSONCoding.decoder().decode(SourceState.self, from: legacy).chain == nil)

        let at = Fixtures.date("2026-09-28 10:00:00")
        let state = SourceState(chain: ChainState(stepIndex: 1, startedAt: at, stepEnteredAt: at, failure: "сломалось"))
        #expect(try JSONCoding.decoder().decode(SourceState.self, from: JSONCoding.encoder().encode(state)) == state)
    }
}
