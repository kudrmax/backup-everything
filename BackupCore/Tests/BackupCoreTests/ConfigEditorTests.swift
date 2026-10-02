import Foundation
import Testing
@testable import BackupCore

struct ConfigEditorTests {
    private let editor = ConfigEditor()
    private let now = Fixtures.date("2026-09-28 10:00:00")
    private let cloud = Destination(name: "Cloud", kind: .localFolder(path: "/c"))
    private let disk = Destination(name: "HDD", kind: .localFolder(path: "/h"))

    private func manual(_ name: String, _ pattern: String, folder: String = "~/Downloads") -> Source {
        Fixtures.source(name: name, steps: [.file(pattern, in: folder, mode: .single, removeOriginal: true)])
    }

    @Test func newSourceGetsUniqueSlugAndCreationDate() {
        var config = Config()
        let first = editor.makeSource(name: "Obsidian", steps: [.folder("/a", excludes: [])], now: now, in: config)
        editor.save(first, in: &config)
        let second = editor.makeSource(name: "Obsidian", steps: [.folder("/b", excludes: [])], now: now, in: config)
        #expect(first.slug == "obsidian")
        #expect(second.slug == "obsidian-2")
        #expect(second.createdAt == now)
        #expect(second.retention == .standard)
    }

    @Test func savedSourceKeepsItsNameAndSlug() {
        var config = Config()
        var source = editor.makeSource(name: "Obsidian", steps: [.folder("/a", excludes: [])], now: now, in: config)
        editor.save(source, in: &config)
        source.name = "Notes"
        source.slug = "tampered"
        source.steps = [.folder("/b", id: source.steps[0].id)]
        editor.save(source, in: &config)
        #expect(config.sources.map(\.name) == ["Obsidian"])
        #expect(config.sources.map(\.slug) == ["obsidian"])
        #expect(config.sources.first?.singleFolder?.path == "/b")
    }

    @Test func folderOfCopiesIsNamedAfterTheNameTheSourceIsFirstSavedWith() {
        var config = Config(sources: [Fixtures.source(name: "Anki")])
        var source = editor.makeSource(name: "New source", steps: [.folder("/a", excludes: [])], now: now, in: config)
        source.name = "Anki"
        editor.save(source, in: &config)
        #expect(config.sources.map(\.slug) == ["anki", "anki-2"])
    }

    @Test func sourcesTakeTheGivenOrder() {
        let a = Fixtures.source(name: "A"), b = Fixtures.source(name: "B"), c = Fixtures.source(name: "C")
        var config = Config(sources: [a, b, c])
        editor.orderSources([c.id, a.id, b.id], in: &config)
        #expect(config.sources.map(\.name) == ["C", "A", "B"])
    }

    @Test func orderingKeepsSourcesMissingFromTheOrderAndIgnoresUnknownIds() {
        let a = Fixtures.source(name: "A"), b = Fixtures.source(name: "B"), c = Fixtures.source(name: "C")
        var config = Config(sources: [a, b, c])
        editor.orderSources([b.id, UUID(), a.id], in: &config)
        #expect(config.sources.map(\.name) == ["B", "A", "C"])
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
        renamed.name = "Cloud"
        editor.save(renamed, in: &config)
        #expect(config.destinations.map(\.name) == ["Cloud"])

        let source = Fixtures.source()
        editor.save(source, in: &config)
        editor.removeSource(source.id, from: &config)
        #expect(config.sources.isEmpty)
    }

    @Test func findsManualSourcesWhoseMasksOverlapInTheSameFolder() {
        let passwords = manual("Passwords", "Passwords*.csv")
        let finance = manual("Finance", "*.csv")
        let photos = manual("Photos", "takeout-*.zip")
        let elsewhere = manual("Other folder", "*.csv", folder: "~/Documents")
        let config = Config(sources: [passwords, finance, photos, elsewhere, Fixtures.source()])

        #expect(editor.maskConflicts(for: passwords, in: config).map(\.name) == ["Finance"])
        #expect(editor.maskConflicts(for: finance, in: config).map(\.name) == ["Passwords"])
        #expect(editor.maskConflicts(for: photos, in: config).isEmpty)
        #expect(editor.maskConflicts(for: Fixtures.source(), in: config).isEmpty)
    }

    @Test func emptyMaskConflictsWithNothing() {
        let blank = manual("Finance", "")
        let config = Config(sources: [blank, manual("Passwords", "Passwords*.csv")])
        #expect(editor.maskConflicts(for: blank, in: config).isEmpty)
    }

    @Test func manualStepMaskConflictsWithManualExportInTheSameFolder() {
        let step = SourceStep(name: "Manifest", kind: .file(instructions: "", watchPath: "~/Downloads", filePattern: "*.json", fileMode: .single, includeInCopy: false, removeOriginal: true))
        let chain = Fixtures.source(name: "Claude", steps: [step])
        let export = manual("Export", "data-*.json")
        let elsewhere = manual("Other folder", "*.json", folder: "~/Desktop")
        let config = Config(sources: [chain, export, elsewhere])
        #expect(editor.maskConflicts(for: chain, in: config).map(\.name) == ["Export"])
        #expect(editor.maskConflicts(for: export, in: config).map(\.name) == ["Claude"])
    }

    @Test func masksThatMatchTheSameFileAreReportedAsOverlapping() {
        let contacts = manual("Contacts", "*.vcf")
        let work = manual("Work contacts", "Work*")
        let passwords = manual("Passwords", "Passwords*.csv")
        let finance = manual("Finance", "*-export.csv")
        let config = Config(sources: [contacts, work, passwords, finance])

        #expect(editor.maskConflicts(for: contacts, in: config).map(\.name) == ["Work contacts"])
        #expect(editor.maskConflicts(for: passwords, in: config).map(\.name) == ["Finance"])
    }

    @Test(arguments: ["~/downloads", "~/Downloads/", "~/Desktop/../Downloads", "~/DOWNLOADS"])
    func sameFolderWrittenDifferentlyIsOneFolder(folder: String) {
        let passwords = manual("Passwords", "Passwords*.csv")
        let finance = manual("Finance", "*.csv", folder: folder)
        #expect(editor.maskConflicts(for: passwords, in: Config(sources: [passwords, finance])).map(\.name) == ["Finance"])
    }

    @Test func orderingWithARepeatedIdUsesItsFirstPlaceAndKeepsTheRestInOrder() {
        let a = Fixtures.source(name: "A"), b = Fixtures.source(name: "B"), c = Fixtures.source(name: "C"), d = Fixtures.source(name: "D")
        var config = Config(sources: [a, b, c, d])
        editor.orderSources([c.id, a.id, c.id], in: &config)
        #expect(config.sources.map(\.name) == ["C", "A", "B", "D"])
    }
}
