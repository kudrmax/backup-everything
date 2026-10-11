import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct OverviewPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let disk = Destination(name: "HDD", kind: .localFolder(path: "/Volumes/HDD"))
    private let cloud = Destination(name: "Cloud", kind: .localFolder(path: "/Users/max/Cloud"))

    private func source(_ steps: [SourceStep], enabled: Bool = true) -> Source {
        Source(name: "Source", slug: "source", steps: steps, schedule: .daily, enabled: enabled, createdAt: now)
    }

    @Test func rowMarkShowsWorkFirstThenWhyItIsQuiet() {
        let failed = SourceStatus.failed("boom")
        #expect(SourceMark.of(stage: .queued, isEnabled: true, status: failed) == .symbol("hourglass"))
        #expect(SourceMark.of(stage: .collecting, isEnabled: true, status: failed) == .working)
        #expect(SourceMark.of(stage: .delivering(destinationId: disk.id), isEnabled: true, status: .ok) == .working)
        #expect(SourceMark.of(stage: nil, isEnabled: false, status: .disabled) == .symbol("pause.circle"))
        #expect(SourceMark.of(stage: nil, isEnabled: true, status: .waiting) == .symbol("clock"))
        #expect(SourceMark.of(stage: nil, isEnabled: true, status: .waitingForDevice) == .symbol("clock"))
        #expect(SourceMark.of(stage: nil, isEnabled: true, status: failed) == .severity(.error))
        #expect(SourceMark.of(stage: nil, isEnabled: true, status: .exportDue) == .severity(.attention))
    }

    @Test func runningNoteAddsTheCommandOutputAndTheStep() {
        let command = source([.command("gh", timeoutSeconds: 60)])
        let chain = source([.file("x-*.zip", in: "~/Downloads"), .command("unpack", timeoutSeconds: 60)])
        #expect(RunProgressText.note(.collecting, of: command, destinationName: nil, status: nil, step: nil) == "preparing the copy…")
        #expect(RunProgressText.note(.collecting, of: command, destinationName: nil, status: "54 of 79 · owner/repo", step: nil)
            == "preparing the copy · 54 of 79 · owner/repo")
        #expect(RunProgressText.note(.delivering(destinationId: disk.id), of: command, destinationName: "HDD", status: nil, step: nil)
            == "copying to “HDD”…")
        #expect(RunProgressText.note(.delivering(destinationId: disk.id), of: command, destinationName: nil, status: nil, step: nil)
            == "copying to “destination”…")
        #expect(RunProgressText.note(.collecting, of: chain, destinationName: nil, status: "downloaded 3 of 5", step: (1, 2))
            == "step 2 of 2 · downloaded 3 of 5")
        #expect(RunProgressText.note(.collecting, of: chain, destinationName: nil, status: nil, step: (1, 2)) == "step 2 of 2 · running the command…")
        #expect(RunProgressText.note(.collecting, of: chain, destinationName: nil, status: nil, step: (5, 6)) == "preparing the copy…")
        #expect(RunProgressText.note(.queued, of: chain, destinationName: nil, status: nil, step: (0, 2)) == "queued")
    }

    @Test func menuShowsStepProgressAndElapsedTime() {
        let started = now.addingTimeInterval(-75)
        #expect(RunProgressText.menuLine(step: (0, 2), status: "3 of 5", startedAt: started, at: now) == "step 1 of 2 · 3 of 5 · 1 min")
        #expect(RunProgressText.menuLine(step: nil, status: nil, startedAt: started, at: now) == "1 min")
        #expect(RunProgressText.menuLine(step: nil, status: nil, startedAt: nil, at: now) == "")
    }

    @Test func ageTipGivesExactTimesAndTheSize() {
        let folder = source([.folder("~/Notes")])
        let last = now.addingTimeInterval(-3_600)
        #expect(RunProgressText.times(folder, lastBackup: nil, nextDue: nil, size: nil, now: now) == "Last backup: never\nNext: manual only")
        #expect(RunProgressText.times(folder, lastBackup: last, nextDue: now, size: 1_500, now: now)
            == "Last backup: \(Texts.dateTime(last))\nNext: due now\nCopy size: 1.5 KB")
        let later = now.addingTimeInterval(86_400)
        #expect(RunProgressText.times(folder, lastBackup: last, nextDue: later, size: nil, now: now)
            == "Last backup: \(Texts.dateTime(last))\nNext: \(Texts.dateTime(later))")
        let export = source([.file("x-*.zip", in: "~/Downloads")])
        #expect(RunProgressText.times(export, lastBackup: nil, nextDue: later, size: nil, now: now)
            == "Last backup: never\nReminder: \(Texts.dateTime(later))")
        let off = source([.folder("~/Notes")], enabled: false)
        #expect(RunProgressText.times(off, lastBackup: nil, nextDue: later, size: nil, now: now) == "Last backup: never")
    }

    @Test func runButtonSaysWhatWillHappen() {
        let folder = source([.folder("~/Notes")])
        let export = source([.file("x-*.zip", in: "~/Downloads"), .command("unpack", timeoutSeconds: 60)])
        let device = source([.device(""), .folder("/Volumes/PB")])
        let chain = ChainState(stepIndex: 1, startedAt: now, stepEnteredAt: now)
        var failed = chain
        failed.failure = "unpack: not found"
        #expect(ChainPosition.runTitle(folder, chain: nil) == "Run")
        #expect(ChainPosition.runTitle(source([]), chain: nil) == "Run")
        #expect(ChainPosition.runTitle(export, chain: nil) == "Run: wait for the export file")
        #expect(ChainPosition.runTitle(device, chain: nil) == "Run: wait for the device")
        #expect(ChainPosition.runTitle(export, chain: chain) == "Run")
        #expect(ChainPosition.runTitle(export, chain: failed) == "Retry step")
    }

    @Test func onlyFullyDownloadedFilesOfferPickUp() {
        #expect(SourceStatus.filesFound(count: 2, bytes: 10, downloading: false).offersPickUp)
        #expect(!SourceStatus.filesFound(count: 2, bytes: 10, downloading: true).offersPickUp)
        #expect(!SourceStatus.exportDue.offersPickUp)
    }

    @Test func copyPlaceExplainsWhyItCannotBeOpened() {
        let open = CopyPlace(destination: disk, folder: URL(fileURLWithPath: "/Volumes/HDD/source/x"), unavailableReason: nil)
        let closed = CopyPlace(destination: cloud, folder: nil, unavailableReason: "No copies yet")
        #expect(open.tip == "Show copy in Finder")
        #expect(open.menuTitle == "HDD")
        #expect(open.id == disk.id)
        #expect(closed.tip == "Open copy: no copies yet")
        #expect(closed.menuTitle == "Cloud — no copies yet")
    }

    @Test func badgeTipSaysWhatHappenedToTheCopy() {
        let delivered = (date: now.addingTimeInterval(-7_200), outcome: DeliveryOutcome.delivered(pruned: 0, warning: nil))
        let failed = (date: now, outcome: DeliveryOutcome.failed(message: "disk full"))
        func details(_ state: DeliveryState, writing: Bool = false, last: (date: Date, outcome: DeliveryOutcome)? = nil) -> String {
            DeliveryText.details(destinationName: "HDD", isWriting: writing, state: state, last: last, now: now)
        }
        #expect(details(.delivered, writing: true) == "HDD\nwriting…")
        #expect(details(.delivered, last: delivered) == "HDD\ndelivered \(Texts.relative(delivered.date, to: now))")
        #expect(details(.delivered) == "HDD\ndelivered ")
        #expect(details(.failed, last: failed) == "HDD\nError: disk full\nretrying later")
        #expect(details(.failed) == "HDD\nerror\nretrying later")
        #expect(details(.none) == "HDD\nno copies yet")
    }

    @Test func badgeMarkFollowsTheDeliveryState() {
        #expect(DeliveryState.delivered.mark == "checkmark.circle.fill")
        #expect(DeliveryState.failed.mark == "xmark.circle.fill")
        #expect(DeliveryState.none.mark == nil)
    }

    @Test func destinationLineShowsSizeAndProblem() {
        #expect(DestinationLink.title(of: disk, used: 2_000_000, condition: .available) == "HDD · 2 MB")
        #expect(DestinationLink.title(of: disk, used: nil, condition: .needsConnection) == "HDD · time to connect")
        #expect(DestinationLink.title(of: cloud, used: nil, condition: .available) == "Cloud")
    }

    @Test func connectedFolderOpensInFinderAndEverythingElseOpensSettings() {
        #expect(DestinationLink.finderFolder(of: disk, isConnected: true)?.path == "/Volumes/HDD")
        #expect(DestinationLink.finderFolder(of: disk, isConnected: false) == nil)
        #expect(DestinationLink.actionTip(for: disk, isConnected: true) == "Click to show in Finder")
        #expect(DestinationLink.actionTip(for: disk, isConnected: false) == "Click to open settings")
    }

    @Test func destinationAttentionJoinsTheProblemAndWhatWaits() {
        #expect(DestinationAttention.text(problem: nil, waiting: []) == nil)
        #expect(DestinationAttention.text(problem: "time to connect", waiting: []) == "time to connect")
        #expect(DestinationAttention.text(problem: nil, waiting: ["Notes", "Photos"]) == "waiting: Notes, Photos")
        #expect(DestinationAttention.text(problem: "unavailable", waiting: ["Notes"]) == "unavailable · waiting: Notes")
    }

    @Test func destinationMarksShowItsCondition() {
        #expect(DestinationCondition.available.mark == "checkmark.circle.fill")
        #expect(DestinationCondition.offline.mark == "minus.circle.fill")
        #expect(DestinationCondition.needsConnection.mark == "clock.fill")
        #expect(DestinationCondition.unreachable.mark == "exclamationmark.circle.fill")
        #expect(DestinationCondition.available.isConnected)
        #expect(!DestinationCondition.offline.isConnected)
        #expect(!DestinationCondition.needsConnection.isConnected)
    }

    @Test func spaceIsShortOnlyWhenKnownFreeSpaceIsLess() {
        let need = WorkingSpace.Need(bytes: 5_000, largest: nil, waitingBytes: 0)
        #expect(WorkingSpace.isShort(need: need, free: 4_999))
        #expect(!WorkingSpace.isShort(need: need, free: 5_000))
        #expect(!WorkingSpace.isShort(need: need, free: nil))
    }

    @Test func sourcesNeverBackedUpNeedNoSpaceYet() {
        let github = source([.command("gh", timeoutSeconds: 60)])
        let telegram = source([.command("tg", timeoutSeconds: 60)])
        let need = WorkingSpace.need(sources: [github, telegram], lastSizes: [:], waiting: [:])
        #expect(need == WorkingSpace.Need(bytes: 0, largest: nil, waitingBytes: 0))
    }

    @Test func spaceLineAndDetailsExplainTheNeed() {
        let github = source([.command("gh", timeoutSeconds: 60)])
        let need = WorkingSpace.Need(bytes: 2_450_000, largest: github, waitingBytes: 50_000)
        #expect(WorkingSpace.line(need: need, free: 9_000_000_000) == "Backups need about 2.5 MB of free space on the laptop · 9 GB free")
        #expect(WorkingSpace.line(need: need, free: nil) == "Backups need about 2.5 MB of free space on the laptop")
        #expect(WorkingSpace.details(need: need) == """
        Backups run one at a time, so there must be room for the largest of those collected into a temporary folder.
        The largest is “Source”.
        Another 50 KB is waiting to be written to a disconnected disk.
        Folders that are copied directly take no temporary space.
        """)
        #expect(WorkingSpace.details(need: WorkingSpace.Need(bytes: 0, largest: nil, waitingBytes: 0)) == """
        Backups run one at a time, so there must be room for the largest of those collected into a temporary folder.
        Folders that are copied directly take no temporary space.
        """)
    }

    @Test func historyFilterKeepsOnlyRunsWithProblems() {
        let good = run([.delivered(pruned: 0, warning: nil)])
        let bad = run([.failed(message: "quota")])
        let broken = run([], collectError: "no folder")
        #expect(RunHistory.runs([good, bad, broken], onlyProblems: false) == [good, bad, broken])
        #expect(RunHistory.runs([good, bad, broken], onlyProblems: true) == [bad, broken])
    }

    @Test func historySeverityAndDetails() {
        let good = run([.delivered(pruned: 0, warning: nil)], snapshot: "2026-10-01_10-00-00", files: 3, bytes: 2_000)
        let waiting = run([.delivered(pruned: 0, warning: nil), .unavailable])
        let bad = run([.failed(message: "quota")])
        let broken = run([], collectError: "no folder")
        #expect(RunHistory.severity(good) == .ok)
        #expect(RunHistory.severity(waiting) == .attention)
        #expect(RunHistory.severity(bad) == .error)
        #expect(RunHistory.copyLine(good) == "2026-10-01_10-00-00, 3 files, 2 KB")
        #expect(RunHistory.copyLine(bad) == nil)
        #expect(RunHistory.copyLine(run([], snapshot: "2026-10-01_10-00-00")) == "2026-10-01_10-00-00, 0 files, 0 B")
        #expect(RunHistory.failure(broken) == "no folder")
        #expect(RunHistory.failure(bad) == "quota")
        #expect(RunHistory.failure(good) == nil)
    }

    private func run(_ outcomes: [DeliveryOutcome], collectError: String? = nil, snapshot: String? = nil, files: Int? = nil, bytes: Int64? = nil) -> RunRecord {
        RunRecord(
            sourceId: UUID(),
            sourceName: "Source",
            trigger: .scheduled,
            startedAt: now,
            finishedAt: now,
            snapshotName: snapshot,
            fileCount: files,
            totalBytes: bytes,
            collectError: collectError,
            deliveries: outcomes.map { Delivery(destinationId: disk.id, destinationName: "HDD", outcome: $0) }
        )
    }
}

@MainActor
struct DestinationDetailsTests {
    @Test func tipSaysWhetherTheDiskIsConnectedAndWhenItIsNeeded() async throws {
        let fixture = try ModelFixture()
        let hdd = fixture.unpluggedDisk("HDD", every: 30)
        let ssd = try fixture.disk("SSD")
        let notes = fixture.source("Notes", steps: [.folder("~/Notes")], to: [hdd, ssd])
        try await fixture.use(Config(sources: [notes], destinations: [hdd, ssd]), state: .backedUp(notes))
        let model = fixture.model
        #expect(await eventually { model.unavailableDestinations == [hdd.id] })

        #expect(DestinationDetails.text(of: hdd, model: model).hasPrefix("Not connected now\nReminder to connect in "))
        #expect(DestinationDetails.text(of: ssd, model: model) == "Available")
    }
}
