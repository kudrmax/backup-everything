import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct DraftTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func source(_ kind: SourceKind) -> Source {
        Source(name: "Источник", slug: "istochnik", kind: kind, schedule: .weekly, createdAt: now)
    }

    @Test(arguments: [
        SourceKind.folder(path: "~/Obsidian", excludes: [".trash", "*.tmp"]),
        SourceKind.command(command: "gh repo list", timeoutSeconds: 600),
        SourceKind.manualExport(watchPath: "~/Downloads", filePattern: "takeout-*.zip", fileMode: .multiple, removeOriginal: false),
    ])
    func sourceDraftRoundTripsEveryKind(kind: SourceKind) {
        let original = source(kind)
        #expect(SourceDraft(original).build() == original)
    }

    @Test func sourceDraftCleansUpUserInput() {
        var draft = SourceDraft(source(.folder(path: "", excludes: [])))
        draft.name = "  Obsidian  "
        draft.folderPath = " ~/Obsidian "
        draft.excludesText = ".trash\n\n  *.tmp  \n"
        let built = draft.build()
        #expect(built.name == "Obsidian")
        #expect(built.kind == .folder(path: "~/Obsidian", excludes: [".trash", "*.tmp"]))
    }

    @Test func sourceDraftExplainsWhatIsMissing() {
        var draft = SourceDraft(source(.folder(path: "", excludes: [])))
        #expect(draft.problem == "Укажите папку или файл источника.")
        draft.folderPath = "~/Obsidian"
        draft.name = " "
        #expect(draft.problem == "Укажите название.")
        draft.name = "Obsidian"
        #expect(draft.problem == nil)

        draft.kindChoice = .command
        #expect(draft.problem == "Укажите команду.")
        draft.kindChoice = .manualExport
        draft.watchPath = "~/Downloads"
        #expect(draft.problem == "Укажите маску файла, например Passwords*.csv.")
    }

    @Test func destinationDraftRoundTrips() {
        let disk = Destination(name: "HDD", kind: .localFolder(path: "/Volumes/HDD/Backups"), expectedEvery: .days(30))
        let cloud = Destination(name: "Облако", kind: .rclone(remote: "gdrive", path: "backups"))
        #expect(DestinationDraft(disk).build() == disk)
        #expect(DestinationDraft(cloud).build() == cloud)
    }

    @Test func destinationDraftExplainsWhatIsMissing() {
        var draft = DestinationDraft(Destination(name: "", kind: .localFolder(path: "")))
        #expect(draft.problem == "Укажите название.")
        draft.name = "HDD"
        #expect(draft.problem == "Выберите папку.")
        draft.typeChoice = .rclone
        #expect(draft.problem == "Выберите подключённое облако.")
        draft.remote = "gdrive"
        #expect(draft.problem == nil)
        draft.isPeriodic = true
        draft.days = 0
        #expect(draft.build().expectedEvery == .days(1))
    }

    @Test func sourceDraftKnowsWhenItDiffersFromTheSavedSource() {
        var draft = SourceDraft(source(.folder(path: "~/Obsidian", excludes: [".trash"])))
        #expect(!draft.hasChanges)
        draft.name = "Источник  "
        draft.excludesText = ".trash\n"
        #expect(!draft.hasChanges)
        draft.schedule = .daily
        #expect(draft.hasChanges)
        draft.schedule = .weekly
        #expect(!draft.hasChanges)
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
        var original = source(.folder(path: "~/Obsidian", excludes: []))
        original.description = "Все заметки"
        original.icon = "a.png"
        var draft = SourceDraft(original)
        #expect(draft.build() == original)

        draft.description = "  Заметки и настройки \n"
        draft.icon = nil
        #expect(draft.hasChanges)
        #expect(draft.build().description == "Заметки и настройки")
        #expect(draft.build().icon == nil)
    }
}
