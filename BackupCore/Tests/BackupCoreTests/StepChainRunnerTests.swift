import Foundation
import Testing
@testable import BackupCore

struct StepChainRunnerTests {
    private let temp: TempDirectory
    private let time: FakeTimeSource
    private let inbox: ManualExportInbox
    private let events = LockedBox<[RunProgress]>([])
    private let start = Fixtures.date("2026-09-28 10:00:00")
    private let created = Fixtures.date("2026-09-27 00:00:00")
    private let allowAll = ChainPermissions(mayStart: true, mayRetry: true)
    private let tickOnly = ChainPermissions(mayStart: false, mayRetry: false)
    private let armed = ChainPermissions(mayStart: true, mayRetry: false)

    init() throws {
        let temp = try TempDirectory()
        self.temp = temp
        time = FakeTimeSource(start)
        try temp.directory("Downloads")
        try temp.directory("trash")
        inbox = ManualExportInbox(pendingRoot: temp.path("pending"), naming: Fixtures.naming) { url in
            try FileManager.default.moveItem(at: url, to: temp.path("trash/\(url.lastPathComponent)"))
        }
    }

    private func runner(_ handler: @escaping @Sendable (FakeProcessRunner.Call) throws -> ProcessResult = { _ in ProcessResult(exitCode: 0) }) -> StepChainRunner {
        StepChainRunner(
            chainsRoot: temp.path("chains"),
            inbox: inbox,
            runner: FakeProcessRunner(output: ["downloaded 1 of 2"], handler: handler),
            time: time,
            trash: { [temp] url in try FileManager.default.moveItem(at: url, to: temp.path("trash/\(url.lastPathComponent)")) },
            progress: { [events] event in events.set(events.get() + [event]) }
        )
    }

    private func manual(_ pattern: String, includeInCopy: Bool = false) -> SourceStep {
        SourceStep(name: "File \(pattern)", kind: .file(instructions: "", watchPath: temp.path("Downloads").path, filePattern: pattern, fileMode: .single, includeInCopy: includeInCopy, removeOriginal: true))
    }

    private func command(_ name: String = "Download archives") -> SourceStep {
        SourceStep(name: name, kind: .command(command: "run \(name)", timeoutSeconds: 60))
    }

    private func source(_ steps: [SourceStep]) -> Source {
        Fixtures.source(name: "Claude", steps: steps, schedule: .monthly, createdAt: created)
    }

    private func chain(_ source: Source, _ index: Int, startedAt: Date, stepEnteredAt: Date, failure: String? = nil) -> ChainState {
        ChainState(
            stepIndex: index,
            stepId: index < source.steps.count ? source.steps[index].id : nil,
            startedAt: startedAt,
            stepEnteredAt: stepEnteredAt,
            failure: failure,
            startedBy: .schedule
        )
    }

    private func writeArchive(_ call: FakeProcessRunner.Call) throws -> ProcessResult {
        let output = URL(fileURLWithPath: call.environment["BACKUP_OUTPUT_DIR"]!)
        try Data("zip".utf8).write(to: output.appendingPathComponent("archive.zip"))
        return ProcessResult(exitCode: 0)
    }

    private func chainFolder(_ source: Source, _ name: String) -> String {
        "chains/\(source.id.uuidString)/\(name)"
    }

    @Test func manualStepWaitsForItsFileAndKeepsItOutOfTheCopy() async throws {
        defer { temp.remove() }
        let source = source([manual("manifest-*.json"), command()])
        let runner = runner()

        #expect(await runner.advance(source, chain: nil, lastPickup: nil, permissions: armed) == .stay)

        try temp.file("Downloads/manifest-a.json", "{}", modified: start.addingTimeInterval(-60))
        let moved = await runner.advance(source, chain: nil, lastPickup: nil, permissions: armed)
        #expect(moved == .moved(chain(source, 1, startedAt: start, stepEnteredAt: start)))
        #expect(temp.names(in: "Downloads").isEmpty)
        #expect(temp.names(in: chainFolder(source, "input")) == ["manifest-a.json"])
        #expect(temp.names(in: chainFolder(source, "output")).isEmpty)
    }

    @Test func manualStepFileCanBePartOfTheCopy() async throws {
        defer { temp.remove() }
        let source = source([manual("export-*.csv", includeInCopy: true)])
        try temp.file("Downloads/export-1.csv", "a;b", modified: start.addingTimeInterval(-60))
        let runner = runner()

        guard case let .moved(chain) = await runner.advance(source, chain: nil, lastPickup: nil, permissions: armed) else {
            Issue.record("step not accepted")
            return
        }
        #expect(temp.names(in: chainFolder(source, "output")) == ["export-1.csv"])

        guard case let .completed(package) = await runner.advance(source, chain: chain, lastPickup: nil, permissions: tickOnly) else {
            Issue.record("chain did not finish")
            return
        }
        #expect(inbox.pendingPackage(for: source.id) == package)
        #expect(temp.names(in: "pending/\(source.id.uuidString)/2026-09-28_100000") == ["export-1.csv"])
        #expect(!temp.exists("chains/\(source.id.uuidString)"))
    }

    @Test func fileOlderThanTheLastPickupIsIgnored() async throws {
        defer { temp.remove() }
        let source = source([manual("manifest-*.json"), command()])
        try temp.file("Downloads/manifest-a.json", "{}", modified: start.addingTimeInterval(-3600))
        let transition = await runner().advance(source, chain: nil, lastPickup: start.addingTimeInterval(-60), permissions: armed)
        #expect(transition == .stay)
        #expect(temp.names(in: "Downloads") == ["manifest-a.json"])
    }

    @Test func commandSeesEarlierFilesAndItsOutputBecomesThePackage() async throws {
        defer { temp.remove() }
        let source = source([manual("manifest-*.json"), command()])
        try temp.file("Downloads/manifest-a.json", "{}", modified: start.addingTimeInterval(-60))
        let seen = LockedBox<[String]>([])
        let runner = runner { [self] call in
            let input = URL(fileURLWithPath: call.environment["BACKUP_INPUT_DIR"]!)
            seen.set(try FileManager.default.contentsOfDirectory(atPath: input.path))
            #expect(FileManager.default.fileExists(atPath: call.environment["BACKUP_SCRATCH_DIR"]!))
            return try writeArchive(call)
        }

        guard case let .moved(afterFile) = await runner.advance(source, chain: nil, lastPickup: nil, permissions: armed) else {
            Issue.record("file not accepted")
            return
        }
        time.advance(10)
        let afterCommand = await runner.advance(source, chain: afterFile, lastPickup: nil, permissions: tickOnly)
        #expect(afterCommand == .moved(chain(source, 2, startedAt: start, stepEnteredAt: start.addingTimeInterval(10))))
        #expect(seen.get() == ["manifest-a.json"])
        #expect(events.get() == [
            .collecting(sourceId: source.id),
            .step(sourceId: source.id, index: 1, count: 2),
            .status(sourceId: source.id, text: "downloaded 1 of 2"),
        ])

        guard case .moved(let done) = afterCommand,
              case let .completed(package) = await runner.advance(source, chain: done, lastPickup: nil, permissions: tickOnly) else {
            Issue.record("chain did not finish")
            return
        }
        #expect(package.collectedAt == start.addingTimeInterval(10))
        #expect(temp.names(in: "pending/\(source.id.uuidString)/2026-09-28_100010") == ["archive.zip"])
        #expect(temp.names(in: "trash") == ["manifest-a.json"])
        #expect(!temp.exists("chains/\(source.id.uuidString)"))
    }

    @Test func failedCommandStaysPutUntilRetryIsAllowed() async throws {
        defer { temp.remove() }
        let source = source([manual("manifest-*.json"), command()])
        try temp.file("Downloads/manifest-a.json", "{}", modified: start.addingTimeInterval(-60))
        let shouldFail = LockedBox(true)
        let runner = runner { [self] call in
            shouldFail.get() ? ProcessResult(exitCode: 1, stderr: "Archives not downloaded: a.zip") : try writeArchive(call)
        }

        guard case let .moved(afterFile) = await runner.advance(source, chain: nil, lastPickup: nil, permissions: armed),
              case let .failed(failed) = await runner.advance(source, chain: afterFile, lastPickup: nil, permissions: tickOnly) else {
            Issue.record("expected a step error")
            return
        }
        #expect(failed.stepIndex == 1)
        #expect(failed.failure == "Command exited with code 1. Archives not downloaded: a.zip")
        #expect(temp.names(in: chainFolder(source, "input")) == ["manifest-a.json"])

        time.advance(7200)
        #expect(await runner.advance(source, chain: failed, lastPickup: nil, permissions: tickOnly) == .stay)

        shouldFail.set(false)
        let retried = await runner.advance(source, chain: failed, lastPickup: nil, permissions: allowAll)
        #expect(retried == .moved(chain(source, 2, startedAt: start, stepEnteredAt: start.addingTimeInterval(7200))))
    }

    @Test func freshFirstStepFileDoesNotRestartAStuckChainByItself() async throws {
        defer { temp.remove() }
        let source = source([manual("manifest-*.json"), command()])
        let failed = chain(source, 1, startedAt: start, stepEnteredAt: start, failure: "links expired")
        try temp.file("chains/\(source.id.uuidString)/input/manifest-a.json", "{}")

        time.advance(600)
        try temp.file("Downloads/manifest-b.json", "{}", modified: start.addingTimeInterval(300))
        #expect(await runner().advance(source, chain: failed, lastPickup: nil, permissions: armed) == .stay)
        #expect(temp.names(in: "Downloads") == ["manifest-b.json"])
        #expect(temp.names(in: "trash").isEmpty)
    }

    @Test func chainThatOpensWithACommandStartsOnlyWhenAllowed() async throws {
        defer { temp.remove() }
        let source = source([command("Open page"), manual("export-*.csv", includeInCopy: true)])
        let runner = runner()

        #expect(await runner.advance(source, chain: nil, lastPickup: nil, permissions: tickOnly) == .stay)
        let started = await runner.advance(source, chain: nil, lastPickup: nil, permissions: ChainPermissions(mayStart: true, mayRetry: false))
        #expect(started == .moved(chain(source, 1, startedAt: start, stepEnteredAt: start)))
    }

    @Test func laterManualStepTakesOnlyFilesThatAppearedAfterThePreviousStep() async throws {
        defer { temp.remove() }
        let source = source([command("Open page"), manual("export-*.csv", includeInCopy: true)])
        let waiting = chain(source, 1, startedAt: start, stepEnteredAt: start)
        let runner = runner()

        time.advance(600)
        try temp.file("Downloads/export-old.csv", "old", modified: start.addingTimeInterval(-60))
        #expect(await runner.advance(source, chain: waiting, lastPickup: nil, permissions: tickOnly) == .stay)

        try temp.file("Downloads/export-new.csv", "new", modified: start.addingTimeInterval(300))
        let moved = await runner.advance(source, chain: waiting, lastPickup: nil, permissions: tickOnly)
        #expect(moved == .moved(chain(source, 2, startedAt: start, stepEnteredAt: start.addingTimeInterval(600))))
        #expect(temp.names(in: "Downloads") == ["export-old.csv"])
        #expect(temp.names(in: chainFolder(source, "output")) == ["export-new.csv"])
    }

    @Test func chainThatProducedNothingFails() async throws {
        defer { temp.remove() }
        let source = source([command()])
        let runner = runner()
        guard case let .moved(done) = await runner.advance(source, chain: nil, lastPickup: nil, permissions: allowAll),
              case let .failed(failed) = await runner.advance(source, chain: done, lastPickup: nil, permissions: tickOnly) else {
            Issue.record("expected an empty result error")
            return
        }
        #expect(failed.stepIndex == 1)
        #expect(failed.failure == SourceError.emptyResult.localizedDescription)
        #expect(inbox.pendingPackage(for: source.id) == nil)
        #expect(await runner.advance(source, chain: failed, lastPickup: nil, permissions: tickOnly) == .stay)
    }

    @Test func chainIsResetWhenStepsWereRemoved() async throws {
        defer { temp.remove() }
        let source = source([command()])
        let stale = chain(source, 3, startedAt: start, stepEnteredAt: start)
        try temp.file("chains/\(source.id.uuidString)/input/manifest-a.json", "{}")
        #expect(await runner().advance(source, chain: stale, lastPickup: nil, permissions: tickOnly) == .moved(nil))
        #expect(temp.names(in: "trash") == ["manifest-a.json"])
    }

    @Test func sourceWithoutStepsDoesNothing() async throws {
        defer { temp.remove() }
        #expect(await runner().advance(source([]), chain: nil, lastPickup: nil, permissions: allowAll) == .stay)
    }

    @Test func newManifestDoesNotDiscardAChainThatIsStillMoving() async throws {
        defer { temp.remove() }
        let source = source([manual("manifest-*.json"), command()])
        let ready = chain(source, 1, startedAt: start, stepEnteredAt: start)
        try temp.file("chains/\(source.id.uuidString)/input/manifest-a.json", "{}")
        let runner = runner { [self] call in try writeArchive(call) }

        time.advance(600)
        try temp.file("Downloads/manifest-a (1).json", "{}", modified: start.addingTimeInterval(300))

        guard case let .moved(done?) = await runner.advance(source, chain: ready, lastPickup: nil, permissions: tickOnly) else {
            Issue.record("the command should have run")
            return
        }
        #expect(done.stepIndex == 2)
        guard case .completed = await runner.advance(source, chain: done, lastPickup: nil, permissions: tickOnly) else {
            Issue.record("the result should have been collected")
            return
        }
        #expect(temp.names(in: "pending/\(source.id.uuidString)/2026-09-28_101000") == ["archive.zip"])
        #expect(temp.names(in: "Downloads") == ["manifest-a (1).json"])
    }

    @Test func assemblyInterruptedAfterThePackageWasStoredStillCompletes() async throws {
        defer { temp.remove() }
        let source = source([command()])
        try temp.file("handover/archive.zip", "zip")
        let stored = try inbox.adopt(sourceId: source.id, directory: temp.path("handover"), at: start.addingTimeInterval(30))
        let assembling = chain(source, 1, startedAt: start, stepEnteredAt: start.addingTimeInterval(30))

        #expect(await runner().advance(source, chain: assembling, lastPickup: nil, permissions: tickOnly) == .completed(stored))
    }

    @Test(arguments: [[1, 2], [0, 2, 1]])
    func chainIsResetWhenTheStepItStoppedOnIsNoLongerInPlace(order: [Int]) async throws {
        defer { temp.remove() }
        let original = source([manual("manifest-*.json"), command("Download"), command("Unpack")])
        let position = chain(original, 1, startedAt: start, stepEnteredAt: start)
        var edited = original
        edited.steps = order.map { original.steps[$0] }
        try temp.file("chains/\(original.id.uuidString)/input/manifest-a.json", "{}")
        let calls = LockedBox(0)
        let runner = runner { _ in
            calls.set(calls.get() + 1)
            return ProcessResult(exitCode: 0)
        }

        #expect(await runner.advance(edited, chain: position, lastPickup: nil, permissions: allowAll) == .moved(nil))
        #expect(calls.get() == 0)
        #expect(temp.names(in: "trash") == ["manifest-a.json"])
    }

    @Test func runnerTellsWhichFilesAChainIsWaitingFor() async throws {
        defer { temp.remove() }
        let source = source([manual("manifest-*.json"), command()])
        let runner = runner()
        #expect(runner.awaitedFiles(source, chain: nil, lastPickup: nil) == .empty)

        try temp.file("Downloads/manifest-a.json", "{}", modified: start.addingTimeInterval(-60))
        try temp.file("Downloads/archive.zip.crdownload", "partial", modified: start.addingTimeInterval(-60))
        let blocked = try #require(runner.awaitedFiles(source, chain: nil, lastPickup: nil))
        #expect(blocked.files.map(\.lastPathComponent) == ["manifest-a.json"])
        #expect(blocked.downloadInProgress)
        #expect(await runner.advance(source, chain: nil, lastPickup: nil, permissions: armed) == .stay)

        let failed = chain(source, 1, startedAt: start.addingTimeInterval(-3600), stepEnteredAt: start.addingTimeInterval(-3600), failure: "x")
        #expect(runner.awaitedFiles(source, chain: failed, lastPickup: nil) == nil)
        let running = chain(source, 1, startedAt: start.addingTimeInterval(-3600), stepEnteredAt: start.addingTimeInterval(-3600))
        #expect(runner.awaitedFiles(source, chain: running, lastPickup: nil) == nil)
    }
}
