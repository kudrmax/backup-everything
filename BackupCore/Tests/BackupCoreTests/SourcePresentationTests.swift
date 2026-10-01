import Foundation
import Testing
@testable import BackupCore

struct SourcePresentationTests {
    @Test func sourceSavedBeforeDescriptionsAndIconsStillLoads() throws {
        var source = Source(name: "Obsidian", slug: "obsidian", steps: [.folder("~/Obsidian", excludes: [])], schedule: .daily, createdAt: Fixtures.date("2026-09-28 10:00:00"))
        var json = try #require(JSONSerialization.jsonObject(with: JSONCoding.encoder().encode(source)) as? [String: Any])
        json["description"] = nil
        json["icon"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: json)

        #expect(try JSONCoding.decoder().decode(Source.self, from: legacy) == source)

        source.description = "All notes"
        source.icon = "a.png"
        #expect(try JSONCoding.decoder().decode(Source.self, from: JSONCoding.encoder().encode(source)) == source)
    }

    @Test func templateSavedBeforeDescriptionsStillLoads() throws {
        let legacy = Data(#"{"id":"x","name":"X","kind":{"folder":{"path":"~/x","excludes":[]}},"schedule":"daily","retention":{"daily":1,"weekly":0,"monthly":0,"yearly":0},"instructions":"steps"}"#.utf8)
        let template = try JSONCoding.decoder().decode(SourceTemplate.self, from: legacy)
        #expect(template.description.isEmpty)
        #expect(template.instructions == "steps")
    }

    @Test func everyBundledTemplateSaysWhatItBacksUp() {
        for template in BundledTemplates.all {
            #expect(!template.description.isEmpty, "\(template.id)")
        }
    }

    @Test func sourceMadeFromTemplateCarriesItsDescription() {
        let source = ConfigEditor().makeSource(
            name: "GitHub",
            steps: [.folder("~/x", excludes: [])],
            description: "All repositories",
            instructions: "steps",
            now: Fixtures.date("2026-09-28 10:00:00"),
            in: Config()
        )
        #expect(source.description == "All repositories")
        #expect(source.instructions == "steps")
    }

    @Test func selfSourceIsDescribedAndNeedsNoInstructions() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let store = Store(dataDirectory: temp.path("data"))
        try Bootstrap(store: store, workDirectory: temp.path("work")).prepare(now: Fixtures.date("2026-09-28 10:00:00"))
        let source = try #require(try store.loadConfig().sources.first)
        #expect(!source.description.isEmpty)
        #expect(source.instructions.isEmpty)
    }

    @Test func iconStoreKeepsEachIconUnderItsOwnName() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let icons = IconStore(directory: temp.path("data/icons"))

        let first = try icons.add(Data("one".utf8))
        let second = try icons.add(Data("two".utf8))

        #expect(first != second)
        #expect(first.hasSuffix(".png"))
        #expect(try Data(contentsOf: icons.url(for: first)) == Data("one".utf8))
        #expect(temp.names(in: "data/icons") == [first, second].sorted())
    }

    @Test func iconStoreDropsIconsNoSourceUses() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let icons = IconStore(directory: temp.path("data/icons"))
        let used = try icons.add(Data("one".utf8))
        _ = try icons.add(Data("two".utf8))

        icons.removeUnused(keeping: [used])

        #expect(temp.names(in: "data/icons") == [used])
        IconStore(directory: temp.path("data/missing")).removeUnused(keeping: [])
    }

    @Test func iconStoreIgnoresNamesThatEscapeItsFolder() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let icons = IconStore(directory: temp.path("data/icons"))
        #expect(icons.url(for: "../config.json").path == temp.path("data/icons/config.json").path)
    }
}
