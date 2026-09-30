import Foundation
import Testing
@testable import BackupCore

struct ConfigEditorTests {
    private let editor = ConfigEditor()
    private let now = Fixtures.date("2026-09-28 10:00:00")
    private let cloud = Destination(name: "Cloud", kind: .localFolder(path: "/c"))
    private let disk = Destination(name: "HDD", kind: .localFolder(path: "/h"))

    private func manual(_ name: String, _ pattern: String, folder: String = "~/Downloads") -> Source {
        Fixtures.source(name: name, kind: .manualExport(watchPath: folder, filePattern: pattern, fileMode: .single, removeOriginal: true))
    }

    @Test func newSourceGetsUniqueSlugAndCreationDate() {
        var config = Config()
        let first = editor.makeSource(name: "Obsidian", kind: .folder(path: "/a", excludes: []), now: now, in: config)
        editor.save(first, in: &config)
        let second = editor.makeSource(name: "Obsidian", kind: .folder(path: "/b", excludes: []), now: now, in: config)
        #expect(first.slug == "obsidian")
        #expect(second.slug == "obsidian-2")
        #expect(second.createdAt == now)
        #expect(second.retention == .standard)
    }

    @Test func savedSourceKeepsItsNameAndSlug() {
        var config = Config()
        var source = editor.makeSource(name: "Obsidian", kind: .folder(path: "/a", excludes: []), now: now, in: config)
        editor.save(source, in: &config)
        source.name = "Заметки"
        source.slug = "tampered"
        source.kind = .folder(path: "/b", excludes: [])
        editor.save(source, in: &config)
        #expect(config.sources.map(\.name) == ["Obsidian"])
        #expect(config.sources.map(\.slug) == ["obsidian"])
        #expect(config.sources.map(\.kind) == [.folder(path: "/b", excludes: [])])
    }

    @Test func folderOfCopiesIsNamedAfterTheNameTheSourceIsFirstSavedWith() {
        var config = Config(sources: [Fixtures.source(name: "Anki")])
        var source = editor.makeSource(name: "Новый источник", kind: .folder(path: "/a", excludes: []), now: now, in: config)
        source.name = "Anki"
        editor.save(source, in: &config)
        #expect(config.sources.map(\.slug) == ["anki", "anki-2"])
    }

    @Test func removingDestinationDetachesItFromSources() {
        var config = Config(sources: [Fixtures.source(destinations: [cloud, disk])], destinations: [cloud, disk])
        editor.removeDestination(disk.id, from: &config)
        #expect(config.destinations == [cloud])
        #expect(config.sources[0].destinationIds == [cloud.id])
    }

    @Test func savesAndRemovesDestinationsAndSources() {
        var config = Config()
        editor.save(cloud, in: &config)
        var renamed = cloud
        renamed.name = "Облако"
        editor.save(renamed, in: &config)
        #expect(config.destinations.map(\.name) == ["Облако"])

        let source = Fixtures.source()
        editor.save(source, in: &config)
        editor.removeSource(source.id, from: &config)
        #expect(config.sources.isEmpty)
    }

    @Test func findsManualSourcesWhoseMasksOverlapInTheSameFolder() {
        let passwords = manual("Пароли", "Passwords*.csv")
        let finance = manual("Финансы", "*.csv")
        let photos = manual("Photos", "takeout-*.zip")
        let elsewhere = manual("Другая папка", "*.csv", folder: "~/Documents")
        let config = Config(sources: [passwords, finance, photos, elsewhere, Fixtures.source()])

        #expect(editor.maskConflicts(for: passwords, in: config).map(\.name) == ["Финансы"])
        #expect(editor.maskConflicts(for: finance, in: config).map(\.name) == ["Пароли"])
        #expect(editor.maskConflicts(for: photos, in: config).isEmpty)
        #expect(editor.maskConflicts(for: Fixtures.source(), in: config).isEmpty)
    }

    @Test func emptyMaskConflictsWithNothing() {
        let blank = manual("Финансы", "")
        let config = Config(sources: [blank, manual("Пароли", "Passwords*.csv")])
        #expect(editor.maskConflicts(for: blank, in: config).isEmpty)
    }

    @Test func manualStepMaskConflictsWithManualExportInTheSameFolder() {
        let step = SourceStep(name: "Манифест", kind: .manual(instructions: "", watchPath: "~/Downloads", filePattern: "*.json", includeInCopy: false))
        let chain = Fixtures.source(name: "Claude", kind: .steps(steps: [step]))
        let export = manual("Экспорт", "data-*.json")
        let elsewhere = manual("Другая папка", "*.json", folder: "~/Desktop")
        let config = Config(sources: [chain, export, elsewhere])
        #expect(editor.maskConflicts(for: chain, in: config).map(\.name) == ["Экспорт"])
        #expect(editor.maskConflicts(for: export, in: config).map(\.name) == ["Claude"])
    }
}
