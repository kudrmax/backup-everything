import BackupCore
import Foundation
import Testing
@testable import BackupEverything

/// Reproductions of bugs found in the app model and presentation. Each test describes the expected behaviour and fails today.
@MainActor
struct FoundBugsAppTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoundBugsAppTests-\(UUID().uuidString)", isDirectory: true)

    private var data: URL { root.appendingPathComponent("data", isDirectory: true) }

    private func makeModel() -> AppModel {
        AppModel(dataDirectory: data, workDirectory: root.appendingPathComponent("work", isDirectory: true))
    }

    private func write(_ text: String, to relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func cleanUp() {
        try? FileManager.default.trashItem(at: root, resultingItemURL: nil)
    }

    @Test func savingWhileTheSettingsFileIsDamagedDoesNotDeleteTheIcons() async throws {
        defer { cleanUp() }
        try write("{ damaged", to: "data/config.json")
        try write("png", to: "data/icons/obsidian.png")
        let model = makeModel()
        model.prepare()
        #expect(model.problem != nil)

        var source = model.newSource(from: nil)
        source.name = "Notes"
        await model.save(source)

        #expect(try String(contentsOf: data.appendingPathComponent("config.json"), encoding: .utf8) == "{ damaged")
        #expect(FileManager.default.fileExists(atPath: data.appendingPathComponent("icons/obsidian.png").path), "icons of sources from the unreadable settings are deleted for good")
    }

    @Test func sourceThatWasNeverDeliveredAnywhereHasNoLastBackup() throws {
        defer { cleanUp() }
        let store = Store(dataDirectory: data)
        let disk = Destination(name: "HDD", kind: .localFolder(path: "/Volumes/HDD"))
        let source = Source(name: "Photos", slug: "photos", steps: [.folder("/tmp/photos")], schedule: .daily, destinationIds: [disk.id], createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        try store.saveConfig(Config(sources: [source], destinations: [disk]))
        var state = AppState()
        state.updateSource(source.id) { $0.lastRun = Date().addingTimeInterval(-3600) }
        try store.saveState(state)

        let model = makeModel()
        model.prepare()

        #expect(model.lastBackup(of: source) == nil, "the disk was unplugged, no copy exists, yet the overview says the last backup was an hour ago")
        #expect(model.latestBackup == nil)
    }

    @Test func copiesOfAJustCreatedSourceAreLookedUpInItsOwnFolder() async throws {
        defer { cleanUp() }
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        try write("{}", to: "backups/photos/2026-09-28_100000/_snapshot.json")
        let model = makeModel()
        model.prepare()
        let disk = Destination(name: "HDD", kind: .localFolder(path: backups.path))
        await model.save(disk)

        var source = model.newSource(from: nil)
        source.name = "Photos"
        source.destinationIds = [disk.id]
        await model.save(source)
        #expect(model.config.source(source.id)?.slug == "photos")

        // SourcesView keeps the source it passed to `save` as the draft; “Show copies by date…” builds from it.
        let previews = await model.retentionPreview(for: source)
        #expect(previews.first?.kept.map(\.name) == ["2026-09-28_100000"])
    }

    @Test func sizesJustBelowAUnitRollOverToTheNextUnit() {
        #expect(Texts.bytes(999_950) == "1 MB")
        #expect(Texts.bytes(999_999_999) == "1 GB")
    }

    @Test func commandWithATimeoutInSecondsIsNotChangedJustByOpeningIt() {
        let source = Source(
            name: "Dump",
            slug: "dump",
            steps: [.command("pg_dump db", timeoutSeconds: 90)],
            schedule: .daily,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        let draft = SourceDraft(source)
        #expect(!draft.hasChanges, "the Save bar appears on a source nobody edited")
        #expect(draft.build().steps == source.steps, "saving any other edit silently cuts the timeout from 90 s to 60 s")
    }
}
