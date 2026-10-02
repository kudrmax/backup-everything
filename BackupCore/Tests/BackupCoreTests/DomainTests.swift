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

    @Test func ordinarySlugIsAFolderName() throws {
        #expect(try Slug.folderName("настройки-backup-everything") == "настройки-backup-everything")
    }

    @Test func deliveryOutcomeTellsAnExtraProblem() {
        #expect(DeliveryOutcome.delivered(pruned: 1, warning: "Could not clean up old copies.").adding("Stuck.")
            == .delivered(pruned: 1, warning: "Could not clean up old copies. Stuck."))
        #expect(DeliveryOutcome.unavailable.adding("Stuck.") == .unavailable)
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

    // MARK: Names when clocks change (Europe/Berlin, 25 October 2026: 03:00 CEST becomes 02:00 CET)

    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    @Test func copiesInTheRepeatedHourCarryTheOffsetAndReadBackAsTheirOwnMoment() {
        let naming = SnapshotNaming(timeZone: berlin)
        let beforeClocksGoBack = Fixtures.date("2026-10-25 00:30:00")
        let anHourLater = Fixtures.date("2026-10-25 01:30:00")

        #expect(naming.name(for: beforeClocksGoBack) == "2026-10-25_023000+0200")
        #expect(naming.name(for: anHourLater) == "2026-10-25_023000+0100")
        #expect(naming.date(from: naming.name(for: beforeClocksGoBack)) == beforeClocksGoBack)
        #expect(naming.date(from: naming.name(for: anHourLater)) == anHourLater)
    }

    @Test(arguments: ["2026-10-24 23:59:59", "2026-10-25 02:00:00", "2026-03-29 00:59:59", "2026-03-29 01:00:00", "2026-07-01 12:00:00"])
    func copiesOutsideTheRepeatedHourKeepPlainLocalNames(moment: String) {
        let naming = SnapshotNaming(timeZone: berlin)
        let date = Fixtures.date(moment)
        #expect(!naming.name(for: date).contains("+"))
        #expect(naming.date(from: naming.name(for: date)) == date)
    }

    @Test func copyNamedInTheRepeatedHourByAnEarlierVersionIsStillACopy() {
        #expect(SnapshotNaming(timeZone: berlin).date(from: "2026-10-25_023000") != nil)
    }

    @Test func copyNamesAreUnambiguousWhenClocksGoBackSoTheFresherCopyOfTheDayIsKept() throws {
        let naming = SnapshotNaming(timeZone: berlin)
        let earlier = Fixtures.date("2026-10-25 00:50:00")
        let later = Fixtures.date("2026-10-25 01:10:00")
        let nextDay = Fixtures.date("2026-10-26 09:00:00")
        let listed = [earlier, later, nextDay].map { naming.snapshot(named: naming.name(for: $0))! }

        #expect(listed[0].date == earlier)
        let doomed = RetentionPolicy(timeZone: berlin)
            .snapshotsToDelete(listed, rules: RetentionRules(daily: 2, weekly: 0, monthly: 0, yearly: 0))
        #expect(doomed.map(\.name) == [naming.name(for: earlier)])
    }

    @Test func utcNamesNeverCarryAnOffset() {
        #expect(Fixtures.naming.name(for: Fixtures.date("2026-10-25 00:30:00")) == "2026-10-25_003000")
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
                Fixtures.source(name: "Obsidian", steps: [.folder("~/Obsidian", excludes: [".trash"])], destinations: [disk, cloud]),
                Fixtures.source(name: "GitHub", steps: [.command("gh repo list", timeoutSeconds: 60)], schedule: .weekly),
                Fixtures.source(
                    name: "Photos",
                    steps: [.file("takeout-*.zip", in: "~/Downloads", mode: .multiple, removeOriginal: true)],
                    schedule: .monthly
                ),
            ],
            destinations: [disk, cloud]
        )
        let data = try JSONCoding.encoder().encode(config)
        #expect(try JSONCoding.decoder().decode(Config.self, from: data) == config)
    }

    @Test func stepsHaveReadableJSONShape() throws {
        let json = #"{"folder":{"path":"~/Obsidian","excludes":[".trash"]}}"#
        #expect(try JSONCoding.decoder().decode(StepKind.self, from: Data(json.utf8)) == .folder(path: "~/Obsidian", excludes: [".trash"]))
        let step = SourceStep.device("/Volumes/PB", instructions: "connect it", id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let encoded = String(decoding: try JSONCoding.encoder(pretty: false).encode(step), as: UTF8.self)
        #expect(encoded == #"{"id":"00000000-0000-0000-0000-000000000001","kind":{"device":{"instructions":"connect it","path":"/Volumes/PB"}},"name":"Connect device"}"#)
    }

    @Test func everyStepKindRoundTripsThroughJSON() throws {
        var source = Fixtures.source(name: "Everything at once", steps: [
            .device("/Volumes/PB", instructions: "connect it"),
            .file("manifest-*.json", in: "~/Downloads", mode: .multiple, includeInCopy: false, removeOriginal: false, instructions: "download it"),
            .command("echo hi", timeoutSeconds: 60),
            .folder("/Volumes/PB/Books", excludes: [".cache"]),
        ])
        source.savesSpace = false
        #expect(try JSONCoding.decoder().decode(Source.self, from: JSONCoding.encoder().encode(source)) == source)
    }

    @Test func sourcesSavedAsOldKindsBecomeSteps() throws {
        let owner = UUID(uuidString: "3A907808-6476-4794-85A6-52CECF2B501F")!
        func legacy(_ kind: String, instructions: String = "how to export") throws -> Source {
            let json = #"{"id":"\#(owner.uuidString)","name":"X","slug":"x","kind":\#(kind),"schedule":"monthly","retention":{"daily":0,"weekly":0,"monthly":12,"yearly":0},"destinationIds":[],"instructions":"\#(instructions)","enabled":true,"createdAt":"2026-09-30T10:00:00Z"}"#
            return try JSONCoding.decoder().decode(Source.self, from: Data(json.utf8))
        }

        let folder = try legacy(#"{"folder":{"path":"~/Obsidian","excludes":[".trash"]}}"#)
        #expect(folder.steps.map(\.kind) == [.folder(path: "~/Obsidian", excludes: [".trash"])])
        #expect(folder.instructions == "how to export")
        #expect(folder.savesSpace)

        let command = try legacy(#"{"command":{"command":"gh repo list","timeoutSeconds":600}}"#)
        #expect(command.steps.map(\.kind) == [.command(command: "gh repo list", timeoutSeconds: 600)])

        let export = try legacy(#"{"manualExport":{"watchPath":"~/Downloads","filePattern":"takeout-*.zip","fileMode":"multiple","removeOriginal":false}}"#)
        #expect(export.steps.map(\.kind) == [.file(instructions: "how to export", watchPath: "~/Downloads", filePattern: "takeout-*.zip", fileMode: .multiple, includeInCopy: true, removeOriginal: false)])
        #expect(export.instructions.isEmpty)

        let device = try legacy(#"{"device":{"path":"/Volumes/PocketBook","excludes":[".cache"]}}"#, instructions: "connect with a cable")
        #expect(device.steps.map(\.kind) == [
            .device(instructions: "connect with a cable", path: ""),
            .folder(path: "/Volumes/PocketBook", excludes: [".cache"]),
        ])
        #expect(device.instructions.isEmpty)
        #expect(try legacy(#"{"device":{"path":"/Volumes/PocketBook","excludes":[]}}"#).steps.map(\.id) == device.steps.map(\.id), "step ids do not change from read to read")

        let chain = try legacy(#"{"steps":{"steps":[{"id":"00000000-0000-0000-0000-000000000002","name":"Manifest","kind":{"manual":{"instructions":"download it","watchPath":"~/Downloads","filePattern":"manifest-*.json","includeInCopy":false}}}]}}"#)
        #expect(chain.steps == [SourceStep(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Manifest",
            kind: .file(instructions: "download it", watchPath: "~/Downloads", filePattern: "manifest-*.json", fileMode: .single, includeInCopy: false, removeOriginal: true)
        )])
        #expect(chain.instructions == "how to export")
    }

    @Test func sourceKnowsWhatItNeedsFromAHuman() {
        let chain = Fixtures.source(steps: [.file("manifest-*.json", in: "~/Downloads", includeInCopy: false), .command("true", timeoutSeconds: 60)])
        #expect(chain.needsHuman)
        #expect(chain.singleFolder == nil)
        #expect(chain.trashesPickedUpFiles)
        #expect(chain.watchedFiles == [WatchedFile(watchPath: "~/Downloads", filePattern: "manifest-*.json")])

        let device = Fixtures.source(steps: [.device("/Volumes/PB"), .folder("/Volumes/PB")])
        #expect(device.needsHuman)
        #expect(device.hasDevice)
        #expect(!device.trashesPickedUpFiles)
        #expect(device.watchedFiles.isEmpty)

        let folder = Fixtures.source()
        #expect(!folder.needsHuman)
        #expect(folder.singleFolder?.path == "/tmp/none")
        #expect(Fixtures.source(steps: [.folder("/a"), .command("true", timeoutSeconds: 1)]).singleFolder == nil)
    }

    @Test func stateSavedBeforeChainsStillLoadsAndChainRoundTrips() throws {
        let legacy = Data(#"{"lastRun":"2026-09-28T10:00:00Z"}"#.utf8)
        #expect(try JSONCoding.decoder().decode(SourceState.self, from: legacy).chain == nil)

        let at = Fixtures.date("2026-09-28 10:00:00")
        let state = SourceState(chain: ChainState(stepIndex: 1, startedAt: at, stepEnteredAt: at, failure: "broke"))
        #expect(try JSONCoding.decoder().decode(SourceState.self, from: JSONCoding.encoder().encode(state)) == state)
    }

    @Test func onlyStepsForThePersonHaveInstructions() {
        #expect(SourceStep.folder("/vault").instructions == nil)
        #expect(SourceStep.command("true", timeoutSeconds: 1).instructions == nil)
        #expect(SourceStep.device("/Volumes/PB", instructions: "Plug in the reader").instructions == "Plug in the reader")
    }

    @Test func devicePathFallsBackToTheNextFolderAndOtherwiseIsUnknown() {
        let byFolder = Fixtures.source(steps: [.device(""), .command("prepare", timeoutSeconds: 10), .folder(""), .folder("/Volumes/PB/Books")])
        #expect(byFolder.devicePath(at: 0) == "/Volumes/PB/Books")
        #expect(byFolder.devicePath(at: 1) == nil)
        #expect(byFolder.devicePath(at: 9) == nil)

        let nowhere = Fixtures.source(steps: [.device(""), .command("copy", timeoutSeconds: 10)])
        #expect(nowhere.devicePath(at: 0) == nil)
    }

    @Test func deviceWithoutAnyPathIsAlwaysAwaited() async {
        let source = Fixtures.source(steps: [.device(""), .command("copy", timeoutSeconds: 10)])
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("BackupCoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let chains = StepChainRunner(
            chainsRoot: temp.appendingPathComponent("chains"),
            inbox: ManualExportInbox(pendingRoot: temp.appendingPathComponent("pending"), naming: Fixtures.naming),
            runner: FakeProcessRunner(),
            time: FakeTimeSource(Fixtures.date("2026-09-28 10:00:00"))
        )
        #expect(chains.awaitsDevice(source, chain: nil))
        #expect(await chains.advance(source, chain: nil, lastPickup: nil, permissions: ChainPermissions(mayStart: true, mayRetry: true)) == .stay)
    }
}
