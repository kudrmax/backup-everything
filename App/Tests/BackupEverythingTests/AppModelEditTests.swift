import BackupCore
import Foundation
import Testing
@testable import BackupEverything

@MainActor
struct AppModelEditTests {
    @Test func savingSettingsAsksForAnImmediateCheck() async throws {
        let fixture = try ModelFixture(prepare: false)
        await fixture.model.orderSources([])
        #expect(fixture.edits == 1)
    }

    @Test func firstLaunchStartsWithTheAppBackingUpItsOwnSettings() throws {
        let fixture = try ModelFixture()
        let model = fixture.model
        #expect(model.problem == nil)
        #expect(model.isFirstLaunch)
        #expect(model.config.sources.map(\.name) == [Bootstrap.selfSourceName])
        #expect(!model.templates.isEmpty)
    }

    @Test func unreadableDataFolderIsReportedInsteadOfStarting() throws {
        let fixture = try ModelFixture(prepare: false)
        try Data("not a folder".utf8).write(to: fixture.store.dataDirectory)
        fixture.model.prepare()
        #expect(fixture.model.problem != nil)
        #expect(fixture.model.config.sources.isEmpty)
    }

    @Test func newSourceIsSavedWithItsDestinationsAndANameBasedFolder() async throws {
        let fixture = try ModelFixture()
        let disk = try fixture.disk()
        await fixture.model.save(disk)
        var source = fixture.model.newSource(from: nil)
        source.name = "Obsidian vault"
        source.destinationIds = [disk.id]
        source.steps = [.folder("~/Obsidian")]
        await fixture.model.save(source)

        let saved = try #require(try fixture.savedConfig().source(source.id))
        #expect(saved.slug == "obsidian-vault")
        #expect(saved.destinationIds == [disk.id])
        #expect(fixture.model.config.source(source.id) == saved)
        #expect(!fixture.model.isFirstLaunch)
    }

    @Test func savingAnExistingSourceChangesItsSettingsButNeverItsNameOrFolder() async throws {
        let fixture = try ModelFixture()
        var source = try #require(fixture.model.config.sources.first)
        source.name = "Renamed"
        source.slug = "renamed"
        source.schedule = .weekly
        await fixture.model.save(source)

        let saved = try #require(try fixture.savedConfig().source(source.id))
        #expect(saved.name == Bootstrap.selfSourceName)
        #expect(saved.slug != "renamed")
        #expect(saved.schedule == .weekly)
    }

    @Test func editKeepsChangesMadeToTheFileSinceItWasRead() async throws {
        let fixture = try ModelFixture()
        var source = try #require(fixture.model.config.sources.first)
        let disk = try fixture.disk()
        var onDisk = try fixture.savedConfig()
        onDisk.destinations.append(disk)
        try fixture.store.saveConfig(onDisk)

        source.schedule = .monthly
        await fixture.model.save(source)

        let saved = try fixture.savedConfig()
        #expect(saved.destinations == [disk])
        #expect(saved.source(source.id)?.schedule == .monthly)
    }

    @Test func damagedSettingsFileIsNeverOverwrittenByAnEdit() async throws {
        let fixture = try ModelFixture()
        let source = try #require(fixture.model.config.sources.first)
        let damaged = Data("{ damaged".utf8)
        try damaged.write(to: fixture.store.configURL)

        await fixture.model.save(source)

        #expect(try Data(contentsOf: fixture.store.configURL) == damaged)
        #expect(fixture.model.problem != nil)
    }

    @Test func everyEditTellsTheAppToReactOnce() async throws {
        let fixture = try ModelFixture()
        let disk = try fixture.disk()
        await fixture.model.save(disk)
        await fixture.model.delete(disk)
        #expect(fixture.edits == 2)
        #expect(fixture.changes == 2)
    }

    @Test func deletingASourceKeepsTheOthers() async throws {
        let fixture = try ModelFixture()
        let notes = fixture.source("Notes", steps: [.folder("~/Notes")])
        await fixture.model.save(notes)
        let own = try #require(fixture.model.config.sources.first)
        await fixture.model.delete(own)
        #expect(try fixture.savedConfig().sources.map(\.id) == [notes.id])
    }

    @Test func deletingADestinationStopsSourcesBackingUpThere() async throws {
        let fixture = try ModelFixture()
        let hdd = try fixture.disk("HDD")
        let ssd = try fixture.disk("SSD")
        let notes = fixture.source("Notes", steps: [.folder("~/Notes")], to: [hdd, ssd])
        try await fixture.use(Config(sources: [notes], destinations: [hdd, ssd]))

        await fixture.model.delete(hdd)

        let saved = try fixture.savedConfig()
        #expect(saved.destinations == [ssd])
        #expect(saved.source(notes.id)?.destinationIds == [ssd.id])
    }

    @Test func savingADestinationAgainUpdatesItInPlace() async throws {
        let fixture = try ModelFixture()
        var disk = try fixture.disk()
        await fixture.model.save(disk)
        disk.expectedEvery = .days(14)
        await fixture.model.save(disk)
        #expect(try fixture.savedConfig().destinations == [disk])
    }

    @Test func sourcesAreReordered() async throws {
        let fixture = try ModelFixture()
        let first = fixture.source("First", steps: [.folder("~/A")])
        let second = fixture.source("Second", steps: [.folder("~/B")])
        try await fixture.use(Config(sources: [first, second]))
        await fixture.model.orderSources([second.id, first.id])
        #expect(fixture.model.config.sources.map(\.name) == ["Second", "First"])
    }

    @Test func emptySourceStartsWithOneFolderStepAndAFreeFolderName() async throws {
        let fixture = try ModelFixture()
        try await fixture.use(Config(sources: [fixture.source("Source", steps: [.folder("~/A")])]))
        let source = fixture.model.newSource(from: nil)
        #expect(source.name == "")
        #expect(source.steps.map(\.kind) == [.folder(path: "", excludes: [])])
        #expect(source.slug == "source-2")
        #expect(source.schedule == .daily)
    }

    @Test func templateFillsTheSourceWithFreshSteps() throws {
        let fixture = try ModelFixture()
        let template = SourceTemplate(
            id: "export",
            name: "Google",
            steps: [.file("takeout-*.zip", in: "~/Downloads", name: "Export")],
            schedule: .monthly,
            retention: RetentionRules(daily: 0, weekly: 0, monthly: 6, yearly: 2),
            description: "Mail and photos",
            instructions: "Open takeout.google.com"
        )
        let source = fixture.model.newSource(from: template)
        #expect(source.name == "Google")
        #expect(source.slug == "google")
        #expect(source.schedule == .monthly)
        #expect(source.retention == template.retention)
        #expect(source.description == "Mail and photos")
        #expect(source.instructions == "Open takeout.google.com")
        #expect(source.steps.map(\.kind) == template.steps.map(\.kind))
        #expect(source.steps.map(\.name) == ["Export"])
        #expect(source.steps[0].id != template.steps[0].id)
    }

    @Test func overlappingMaskInTheSameFolderIsFoundBeforeSaving() async throws {
        let fixture = try ModelFixture()
        let google = fixture.source("Google", steps: [.file("takeout-*.zip", in: "~/Downloads")])
        try await fixture.use(Config(sources: [google]))
        let other = fixture.source("Other", steps: [.file("takeout-2024*.zip", in: "~/Downloads")])
        let elsewhere = fixture.source("Elsewhere", steps: [.file("takeout-*.zip", in: "~/Desktop")])
        #expect(fixture.model.maskConflicts(for: other).map(\.name) == ["Google"])
        #expect(fixture.model.maskConflicts(for: elsewhere).isEmpty)
        #expect(fixture.model.maskConflicts(for: google).isEmpty)
    }

    @Test func chosenPictureBecomesTheSourceIcon() throws {
        let fixture = try ModelFixture()
        let name = try #require(fixture.model.importIcon(from: try fixture.picture()))
        let image = try #require(fixture.model.iconImage(name))
        #expect(image.size.width == 128)
        #expect(fixture.model.iconImage(name) === image)
        #expect(fixture.model.iconImage(nil) == nil)
        #expect(fixture.model.problem == nil)
    }

    @Test func fileThatIsNotAPictureIsRejectedWithAnExplanation() throws {
        let fixture = try ModelFixture()
        let file = try fixture.temp.file("notes.txt")
        #expect(fixture.model.importIcon(from: file) == nil)
        #expect(fixture.model.problem == "Could not read the image “notes.txt”.")
        fixture.model.dismissProblem()
        #expect(fixture.model.problem == nil)
    }

    @Test func iconThatCannotBeStoredIsReported() throws {
        let fixture = try ModelFixture()
        try Data("in the way".utf8).write(to: fixture.store.iconsDirectory)
        #expect(fixture.model.importIcon(from: try fixture.picture()) == nil)
        #expect(fixture.model.problem != nil)
    }

    @Test func iconsNoSourceUsesAreDropped() async throws {
        let fixture = try ModelFixture()
        let kept = try #require(fixture.model.importIcon(from: try fixture.picture("kept.png")))
        let dropped = try #require(fixture.model.importIcon(from: try fixture.picture("dropped.png")))
        var source = fixture.source("Notes", steps: [.folder("~/Notes")])
        source.icon = kept
        await fixture.model.save(source)
        let icons = try FileManager.default.contentsOfDirectory(atPath: fixture.store.iconsDirectory.path)
        #expect(icons == [kept])
        #expect(!icons.contains(dropped))

        await fixture.model.delete(source)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.store.iconsDirectory.path).isEmpty)
    }
}
