import AppKit
import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct SettingsPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func source(_ steps: [SourceStep], name: String = "Source") -> Source {
        Source(name: name, slug: name.lowercased(), steps: steps, schedule: .weekly, createdAt: now)
    }

    @Test func emptySourceGetsTheStepsOfTheChosenStartTemplateKeepsItsOwn() {
        let empty = source([.folder("")])
        #expect(SourceDraft(empty, startingWith: .device).steps.map(\.kindChoice) == [.device, .folder])
        let template = source([.command("gh", timeoutSeconds: 60)])
        #expect(SourceDraft(template, startingWith: nil).build() == template)
    }

    @Test func instructionsAreSummedUpByTheirFirstLine() {
        var draft = SourceDraft(source([.folder("~/A")]))
        #expect(draft.instructionsSummary == "none")
        draft.instructions = "Sign in to gh\nthen run it once"
        #expect(draft.instructionsSummary == "Sign in to gh")
        draft.instructions = "\n\nSecond line only"
        #expect(draft.instructionsSummary == "Second line only")
    }

    @Test func maskWarningIsShownOnlyForSourcesThatWaitForFiles() {
        var draft = SourceDraft(source([.folder("~/A")]))
        #expect(!draft.watchesFiles)
        draft.steps.append(StepDraft(new: .file))
        #expect(draft.watchesFiles)
        #expect(Texts.maskOverlap([]) == nil)
        #expect(Texts.maskOverlap([source([], name: "Google")]) == "The mask overlaps with the source “Google” in the same folder.")
        #expect(Texts.maskOverlap([source([], name: "Google"), source([], name: "Claude")])
            == "The mask overlaps with the source “Google”, “Claude” in the same folder.")
    }

    @Test func destinationChipsAddAndRemoveDestinations() {
        let hdd = UUID()
        let ssd = UUID()
        var original = source([.folder("~/A")])
        original.destinationIds = [ssd]
        var draft = SourceDraft(original)
        draft.setDestination(hdd, included: true)
        #expect(draft.destinationIds == [hdd, ssd])
        draft.setDestination(ssd, included: false)
        #expect(draft.build().destinationIds == [hdd])
    }

    @Test func savedOrderOfDestinationsIsKeptAndNewOnesFollowInAStableOrder() {
        let ids = (0..<4).map { _ in UUID() }
        var original = source([.folder("~/A")])
        original.destinationIds = [ids[0], ids[1]]
        var draft = SourceDraft(original)
        draft.setDestination(ids[2], included: true)
        draft.setDestination(ids[3], included: true)
        let added = [ids[2], ids[3]].sorted { $0.uuidString < $1.uuidString }
        #expect(draft.build().destinationIds == [ids[0], ids[1]] + added)
    }

    @Test func draftSymbolFollowsItsSteps() {
        var draft = SourceDraft(source([.command("gh", timeoutSeconds: 60)]))
        #expect(draft.symbol == "terminal")
        draft.steps.append(StepDraft(new: .folder))
        #expect(draft.symbol == "list.number")
        #expect(draft.id == draft.build().id)
    }

    @Test func excludedMasksAreListedOrNothing() {
        var step = StepDraft(new: .folder)
        #expect(step.excludesSummary == "nothing")
        step.excludesText = "*.tmp\n.cache\n"
        #expect(step.excludesSummary == "*.tmp, .cache")
    }

    @Test func stepListNumbersStepsOnlyWhenThereAreSeveral() {
        #expect(StepList.title(count: 1) == "What to do")
        #expect(StepList.title(count: 2) == "What to do · steps run in order")
        #expect(StepList.number(of: 0, count: 1) == nil)
        #expect(StepList.number(of: 1, count: 3) == 2)
        let steps = [StepDraft(new: .device), StepDraft(new: .command), StepDraft(new: .folder)]
        #expect(StepList.isFollowedByFolder(steps, at: 0))
        #expect(StepList.isFollowedByFolder(steps, at: 1))
        #expect(!StepList.isFollowedByFolder(steps, at: 2))
    }

    @Test func choicesHaveTitlesAndSymbols() {
        #expect(StepKindChoice.allCases.map(\.symbol) == ["folder", "terminal", "square.and.arrow.down", "cable.connector"])
        #expect(StepKindChoice.allCases.map(\.id) == ["folder", "command", "file", "device"])
        #expect(SourceStart.allCases.map(\.title) == ["Folder", "Command", "File you export yourself", "Folder on a connected device"])
        #expect(SourceStart.allCases.map(\.id) == ["folder", "command", "file", "device"])
        #expect(DestinationTypeChoice.allCases.map(\.title) == ["Folder or disk", "Cloud (rclone)"])
        #expect(DestinationTypeChoice.allCases.map(\.id) == ["local", "rclone"])
        #expect(OverviewOrder.allCases.map(\.title) == ["As in settings", "By next backup"])
        #expect(OverviewOrder.allCases.map(\.id) == ["manual", "nextBackup"])
    }

    @Test func destinationDraftKeepsItsId() {
        let disk = Destination(name: "HDD", kind: .localFolder(path: "/Volumes/HDD"))
        #expect(DestinationDraft(disk).id == disk.id)
    }

    @Test func retentionFootnoteSaysWhetherHistoryIsKept() {
        #expect(RetentionPlan.footnote(.standard) == RetentionPlan.footnote)
        #expect(RetentionPlan.footnote(RetentionRules(daily: 0, weekly: 0, monthly: 0, yearly: 0)) == RetentionPlan.newestOnly)
        #expect(RetentionStage.Unit.allCases.map(\.maximum) == [365, 104, 120, 50])
        #expect(RetentionPlan.stages(.standard).map(\.id) == RetentionStage.Unit.allCases)
    }

    @Test func scheduleTriggerAndOverallTexts() {
        #expect(Schedule.allCases.map(Texts.schedule) == ["Every day", "Once a week", "Once a month", "Manual only"])
        #expect([RunTrigger.scheduled, .manual, .catchUp, .pickup].map(Texts.trigger) == ["Scheduled", "Manual", "Catch-up", "File pickup"])
        #expect([OverallStatus.ok, .attention, .error].map(Texts.overall) == ["All good", "Needs attention", "Errors"])
    }

    @Test func deliveryOutcomeTexts() {
        #expect(Texts.outcome(.delivered(pruned: 0, warning: nil)) == "Delivered")
        #expect(Texts.outcome(.delivered(pruned: 3, warning: nil)) == "Delivered, old copies removed: 3")
        #expect(Texts.outcome(.delivered(pruned: 0, warning: "cleanup failed")) == "Delivered. cleanup failed")
        #expect(Texts.outcome(.unavailable) == "Unavailable, waiting")
        #expect(Texts.outcome(.failed(message: "disk full")) == "Error: disk full")
    }

    @Test func statusTextsForTheTip() {
        let statuses: [SourceStatus] = [
            .disabled, .failed("boom"), .overdue(nil), .noDestinations, .warning("Could not clean up old copies: busy"),
            .filesFound(count: 2, bytes: 1_500, downloading: false), .filesFound(count: 1, bytes: 10, downloading: true),
            .exportDue, .waiting, .deviceDue, .waitingForDevice, .neverRun, .unconfirmed, .ok,
        ]
        #expect(statuses.map(\.text) == [
            "Disabled", "Error: boom", "Backup is long overdue", "No destination chosen", "Delivered, but: Could not clean up old copies: busy",
            "Files found: 2, 1.5 KB", "Files found: 1, 10 B. Downloading",
            "Time to export", "Waiting for a file: download it and the backup starts on its own", "Time to connect the device",
            "Waiting for the device: connect it and the backup starts on its own", "Never run", "No fresh copy confirmed yet",
            "OK: a fresh copy on every destination",
        ])
    }

    @Test func menuLineNamesItsSubject() {
        let notes = source([.folder("~/Notes")], name: "Notes")
        let disk = Destination(name: "HDD", kind: .localFolder(path: "/Volumes/HDD"))
        let sourceLine = MenuLine(subject: .source(notes), severity: .error, text: "boom", canPickUp: false)
        let diskLine = MenuLine(subject: .destination(disk), severity: .attention, text: "time to connect", canPickUp: false)
        #expect(sourceLine.id == notes.id)
        #expect(sourceLine.name == "Notes")
        #expect(diskLine.id == disk.id)
        #expect(diskLine.name == "HDD")
    }

    @Test func statusSymbolsAndColours() {
        #expect(StatusStyle.menuBarSymbol(.error, working: true) == "arrow.triangle.2.circlepath")
        #expect([OverallStatus.ok, .attention, .error].map { StatusStyle.menuBarSymbol($0, working: false) }
            == ["externaldrive.badge.checkmark", "externaldrive.badge.exclamationmark", "externaldrive.badge.xmark"])
        #expect([OverallStatus.ok, .attention, .error].map(StatusStyle.symbol) == ["checkmark.circle.fill", "exclamationmark.circle.fill", "xmark.octagon.fill"])
        #expect([OverallStatus.ok, .attention, .error].map(StatusStyle.color) == [.green, .orange, .red])
        #expect(StatusStyle.symbol(for: .localFolder(path: "/")) == "externaldrive")
        #expect(StatusStyle.symbol(for: .rclone(remote: "r", path: "p")) == "cloud")
    }

    @Test func sourceSymbolFollowsItsOnlyStep() {
        #expect(StatusStyle.symbol(for: source([.folder("~/A")])) == "folder")
        #expect(StatusStyle.symbol(for: source([.command("gh", timeoutSeconds: 60)])) == "terminal")
        #expect(StatusStyle.symbol(for: source([.file("x", in: "~")])) == "square.and.arrow.down")
        #expect(StatusStyle.symbol(for: source([.device("/Volumes/PB")])) == "cable.connector")
        #expect(StatusStyle.symbol(for: source([.device(""), .folder("/Volumes/PB")])) == "list.number")
    }

    @Test func menuBarIconIsTintedOnlyWhenSomethingIsWrong() {
        #expect(MenuBarTint.standard.color == nil)
        #expect(MenuBarTint.attention.color == .systemYellow)
        #expect(MenuBarTint.error.color == .systemRed)
    }

    @Test func dropLineGoesWhereTheItemWillLand() {
        let ids = [UUID(), UUID(), UUID()]
        #expect(ListOrder.dropsBelow(ids[0], onto: ids[2], in: ids))
        #expect(!ListOrder.dropsBelow(ids[2], onto: ids[0], in: ids))
        #expect(!ListOrder.dropsBelow(nil, onto: ids[0], in: ids))
        #expect(!ListOrder.dropsBelow(UUID(), onto: ids[0], in: ids))
    }

    @Test func chipsWrapWhenTheRowIsFull() {
        let sizes = [CGSize(width: 40, height: 20), CGSize(width: 40, height: 24), CGSize(width: 40, height: 20)]
        #expect(FlowLine.lines(sizes: sizes, width: 200, spacing: 6) == [FlowLine(indices: [0, 1, 2], width: 132, height: 24)])
        #expect(FlowLine.lines(sizes: sizes, width: 90, spacing: 6) == [
            FlowLine(indices: [0, 1], width: 86, height: 24),
            FlowLine(indices: [2], width: 40, height: 20),
        ])
        #expect(FlowLine.lines(sizes: [CGSize(width: 300, height: 20)], width: 100, spacing: 6) == [FlowLine(indices: [0], width: 300, height: 20)])
        #expect(FlowLine.lines(sizes: [], width: 100, spacing: 6) == [FlowLine()])
    }

    @Test func tooltipSitsUnderTheElementAndStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 200, height: 40)
        #expect(TooltipPlacement.origin(size: size, below: CGRect(x: 400, y: 400, width: 100, height: 20), on: screen, gap: 6)
            == CGPoint(x: 350, y: 354))
        #expect(TooltipPlacement.origin(size: size, below: CGRect(x: 400, y: 10, width: 100, height: 20), on: screen, gap: 6)
            == CGPoint(x: 350, y: 36))
        #expect(TooltipPlacement.origin(size: size, below: CGRect(x: 0, y: 400, width: 20, height: 20), on: screen, gap: 6).x == 4)
        #expect(TooltipPlacement.origin(size: size, below: CGRect(x: 980, y: 400, width: 20, height: 20), on: screen, gap: 6).x == 796)
    }

    @Test func unplugEventDoesNotChangeWhatIsShownAndOnlyWritingWithoutCollectingIsCopying() {
        let source = UUID()
        var tracker = ActivityTracker()
        tracker.apply(.collecting(sourceId: source))
        tracker.apply(.canUnplug(sourceId: source, sourceName: "PocketBook"))
        #expect(tracker.stage(of: source) == .collecting)
        #expect(!tracker.isCopying(source))
        #expect(tracker.active == [source])
    }
}
