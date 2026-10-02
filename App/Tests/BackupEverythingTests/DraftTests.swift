import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct DraftTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func source(_ steps: [SourceStep]) -> Source {
        Source(name: "Source", slug: "source", steps: steps, schedule: .weekly, createdAt: now)
    }

    @Test(arguments: [
        [SourceStep.folder("~/Obsidian", excludes: [".trash", "*.tmp"])],
        [SourceStep.command("gh repo list", timeoutSeconds: 600)],
        [SourceStep.file("takeout-*.zip", in: "~/Downloads", mode: .multiple, includeInCopy: true, removeOriginal: false, instructions: "export it")],
        [SourceStep.device("/Volumes/PocketBook", instructions: "connect it"), SourceStep.folder("/Volumes/PocketBook/Books", excludes: [".cache"])],
        [
            SourceStep.file("manifest-*.json", in: "~/Downloads", includeInCopy: false, instructions: "download it", name: "Manifest"),
            SourceStep.command("echo hi", timeoutSeconds: 3600, name: "Archives"),
        ],
    ])
    func sourceDraftRoundTripsAnySteps(steps: [SourceStep]) {
        let original = source(steps)
        #expect(SourceDraft(original).build() == original)
    }

    @Test func sourceDraftCleansUpUserInput() {
        var draft = SourceDraft(source([.folder("")]))
        draft.name = "  Obsidian  "
        draft.steps[0].folderPath = " ~/Obsidian "
        draft.steps[0].excludesText = ".trash\n\n  *.tmp  \n"
        let built = draft.build()
        #expect(built.name == "Obsidian")
        #expect(built.steps.map(\.kind) == [.folder(path: "~/Obsidian", excludes: [".trash", "*.tmp"])])
    }

    @Test func eachWayToStartGivesItsSteps() {
        #expect(SourceStart.folder.steps.map(\.kindChoice) == [.folder])
        #expect(SourceStart.command.steps.map(\.kindChoice) == [.command])
        #expect(SourceStart.file.steps.map(\.kindChoice) == [.file])
        #expect(SourceStart.device.steps.map(\.kindChoice) == [.device, .folder])
    }

    @Test func sourceDraftExplainsWhatIsMissing() {
        var draft = SourceDraft(source([]))
        #expect(draft.problem == "Add at least one step.")

        draft.steps = SourceStart.folder.steps
        #expect(draft.problem == "Choose a folder or file.")
        draft.steps[0].folderPath = "~/Obsidian"
        draft.name = " "
        #expect(draft.problem == "Enter a name.")
        draft.name = "Obsidian"
        #expect(draft.problem == nil)

        draft.steps = [StepDraft(new: .file), StepDraft(new: .command)]
        #expect(draft.problem == "Step 1: enter a file mask, e.g. manifest-*.json.")
        draft.steps[0].filePattern = " manifest-*.json "
        #expect(draft.problem == "Step 2: enter a command.")
        draft.steps[1].command = "echo hi"
        draft.steps[1].name = "  "
        #expect(draft.problem == "Step 2: enter a name.")
        draft.steps[1].name = " Download "
        draft.steps[0].watchPath = ""
        #expect(draft.problem == "Step 1: choose the folder the file lands in.")
        draft.steps[0].watchPath = "~/Downloads"
        #expect(draft.problem == nil)
        #expect(draft.build().steps.map(\.kind) == [
            .file(instructions: "", watchPath: "~/Downloads", filePattern: "manifest-*.json", fileMode: .single, includeInCopy: true, removeOriginal: true),
            .command(command: "echo hi", timeoutSeconds: 3600),
        ])
    }

    @Test func deviceWithoutItsOwnPathIsSavedEmptyAndFollowsTheNextFolder() {
        var draft = SourceDraft(source([]))
        draft.name = "PocketBook"
        draft.steps = SourceStart.device.steps
        #expect(draft.problem == "Step 2: choose a folder or file.")
        draft.steps[1].folderPath = "/Volumes/PocketBook/Books"
        #expect(draft.problem == nil)
        let built = draft.build()
        #expect(built.steps.map(\.kind) == [
            .device(instructions: "", path: ""),
            .folder(path: "/Volumes/PocketBook/Books", excludes: []),
        ])
        #expect(built.devicePath(at: 0) == "/Volumes/PocketBook/Books")

        draft.steps.removeLast()
        #expect(draft.problem == "Enter the path on the device.")
    }

    @Test func stepDraftKeepsBothFormsWhileTheKindIsSwitched() {
        var step = StepDraft(SourceStep(name: "Archives", kind: .command(command: "echo hi", timeoutSeconds: 1800)))
        #expect(step.timeoutMinutes == 30)
        step.kindChoice = .file
        step.filePattern = "x-*.zip"
        step.kindChoice = .command
        #expect(step.build().kind == .command(command: "echo hi", timeoutSeconds: 1800))
    }

    @Test func destinationDraftRoundTrips() {
        let disk = Destination(name: "HDD", kind: .localFolder(path: "/Volumes/HDD/Backups"), expectedEvery: .days(30))
        let cloud = Destination(name: "Cloud", kind: .rclone(remote: "gdrive", path: "backups"))
        #expect(DestinationDraft(disk).build() == disk)
        #expect(DestinationDraft(cloud).build() == cloud)
    }

    @Test func destinationDraftExplainsWhatIsMissing() {
        var draft = DestinationDraft(Destination(name: "", kind: .localFolder(path: "")))
        #expect(draft.problem == "Enter a name.")
        draft.name = "HDD"
        #expect(draft.problem == "Choose a folder.")
        draft.typeChoice = .rclone
        #expect(draft.problem == "Choose a connected cloud.")
        draft.remote = "gdrive"
        #expect(draft.problem == nil)
        draft.isPeriodic = true
        draft.days = 0
        #expect(draft.build().expectedEvery == .days(1))
    }

    @Test func sourceDraftKnowsWhenItDiffersFromTheSavedSource() {
        let saved = source([.folder("~/Obsidian")])
        var draft = SourceDraft(saved)
        #expect(!draft.hasChanges)
        draft.schedule = .daily
        #expect(draft.hasChanges)
        draft.schedule = .weekly
        #expect(!draft.hasChanges)
        draft.steps[0].folderPath = "~/Notes"
        #expect(draft.hasChanges)
    }

    @Test func destinationDraftKnowsWhenItDiffersFromTheSavedDestination() {
        var draft = DestinationDraft(Destination(name: "HDD", kind: .localFolder(path: "/Volumes/HDD")))
        #expect(!draft.hasChanges)
        draft.days = 10
        #expect(!draft.hasChanges)
        draft.isPeriodic = true
        #expect(draft.hasChanges)
    }

    @Test func sourceDraftCarriesDescriptionAndIcon() {
        var original = source([.folder("~/Obsidian")])
        original.description = "All notes"
        original.icon = "a.png"
        var draft = SourceDraft(original)
        #expect(draft.build() == original)
        draft.description = "  Notes  "
        draft.icon = nil
        #expect(draft.build().description == "Notes")
        #expect(draft.build().icon == nil)
    }

    @Test func commandWithATimeoutInSecondsIsNotChangedJustByOpeningIt() {
        let original = source([.command("pg_dump db", timeoutSeconds: 90)])
        var draft = SourceDraft(original)
        #expect(draft.steps[0].timeoutMinutes == 1)
        #expect(!draft.hasChanges)
        draft.name = "Dump"
        #expect(draft.build().steps == original.steps)
    }

    @Test func changedTimeoutIsSavedInWholeMinutes() {
        var draft = SourceDraft(source([.command("pg_dump db", timeoutSeconds: 90)]))
        draft.steps[0].timeoutMinutes = 5
        #expect(draft.build().steps[0].kind == .command(command: "pg_dump db", timeoutSeconds: 300))
        draft.steps[0].timeoutMinutes = 1
        #expect(draft.build().steps[0].kind == .command(command: "pg_dump db", timeoutSeconds: 90))
    }
}
