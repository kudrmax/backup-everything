import Foundation
import Testing
@testable import BackupCore

struct StoreTests {
    private let temp: TempDirectory
    private let store: Store

    init() throws {
        temp = try TempDirectory()
        store = Store(dataDirectory: temp.path("data"))
    }

    @Test func missingFilesYieldDefaults() throws {
        defer { temp.remove() }
        #expect(try store.loadConfig() == Config())
        #expect(try store.loadState() == AppState())
        #expect(store.loadRuns().isEmpty)
        #expect(!store.hasConfig)
    }

    @Test func configAndStateRoundTrip() throws {
        defer { temp.remove() }
        let config = Config(sources: [Fixtures.source()], destinations: [])
        var state = AppState()
        state.updateSource(config.sources[0].id) { $0.lastRun = Fixtures.date("2026-09-28 10:00:00") }
        state.debts = [Debt(sourceId: config.sources[0].id, destinationId: UUID(), since: Fixtures.date("2026-09-28 10:00:00"))]
        try store.saveConfig(config)
        try store.saveState(state)
        #expect(try store.loadConfig() == config)
        #expect(try store.loadState() == state)
        #expect(store.hasConfig)
    }

    @Test func corruptedConfigIsReportedAndLeftUntouched() throws {
        defer { temp.remove() }
        try temp.file("data/config.json", "{ not json")
        #expect(throws: StoreError.corrupted(file: "config.json")) { try store.loadConfig() }
        #expect(try String(contentsOf: store.configURL, encoding: .utf8) == "{ not json")
    }

    @Test func corruptedStateIsSetAsideAndReset() throws {
        defer { temp.remove() }
        try temp.file("data/state.json", "garbage")
        #expect(try store.loadState() == AppState())
        #expect(temp.names(in: "data").contains { $0.hasPrefix("state.json.corrupt-") })
        #expect(!temp.exists("data/state.json"))
    }

    @Test func newerSchemaIsRejected() throws {
        defer { temp.remove() }
        try temp.file("data/config.json", #"{"schemaVersion":99,"sources":[],"destinations":[]}"#)
        #expect(throws: StoreError.unsupportedVersion(file: "config.json", version: 99)) { try store.loadConfig() }
    }

    @Test func historyIsAppendedPerMonthAndReadNewestFirst() throws {
        defer { temp.remove() }
        let sourceId = UUID()
        let starts = ["2026-08-31 23:00:00", "2026-09-01 08:00:00", "2026-09-02 08:00:00"].map(Fixtures.date)
        for start in starts {
            try store.appendRun(RunRecord(sourceId: sourceId, sourceName: "Obsidian", trigger: .scheduled, startedAt: start, finishedAt: start))
        }
        #expect(temp.names(in: "data/history") == ["2026-08.jsonl", "2026-09.jsonl"])
        #expect(store.loadRuns().map(\.startedAt) == starts.reversed())
        #expect(store.loadRuns(limit: 2).map(\.startedAt) == [starts[2], starts[1]])
    }

    @Test func damagedHistoryLineIsSkipped() throws {
        defer { temp.remove() }
        let start = Fixtures.date("2026-09-01 08:00:00")
        try store.appendRun(RunRecord(sourceId: UUID(), sourceName: "A", trigger: .manual, startedAt: start, finishedAt: start))
        let handle = try FileHandle(forWritingTo: temp.path("data/history/2026-09.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{broken\n".utf8))
        try handle.close()
        try store.appendRun(RunRecord(sourceId: UUID(), sourceName: "B", trigger: .manual, startedAt: start.addingTimeInterval(60), finishedAt: start))
        #expect(store.loadRuns().map(\.sourceName) == ["B", "A"])
    }

    @Test func bundledTemplatesInstallOnceAndAllDecode() throws {
        defer { temp.remove() }
        try store.installBundledTemplates()
        #expect(temp.names(in: "data/templates") == [
            "apple-contacts.json", "apple-passwords.json", "bitwarden.json", "claude-code.json", "claude.json", "github.json",
            "google-photos.json", "ios-finance.json", "obsidian.json",
        ])
        #expect(store.loadTemplates().count == 9)

        try temp.file("data/templates/obsidian.json", "edited by user")
        try store.installBundledTemplates()
        #expect(try String(contentsOf: temp.path("data/templates/obsidian.json"), encoding: .utf8) == "edited by user")
        #expect(store.loadTemplates().count == 8)
    }

    @Test func unreadableConfigIsAnErrorNotAnEmptyConfig() throws {
        defer { temp.remove() }
        try temp.directory("data/config.json")
        #expect(throws: StoreError.unreadable(file: "config.json")) { try store.loadConfig() }
    }

    @Test func financeTemplateShipsWithoutCatchAllMask() throws {
        defer { temp.remove() }
        try store.installBundledTemplates()
        let finance = try #require(store.loadTemplates().first { $0.id == "ios-finance" })
        #expect(finance.steps.map(\.kind) == [.file(instructions: finance.steps[0].instructions ?? "", watchPath: "~/Downloads", filePattern: "", fileMode: .single, includeInCopy: true, removeOriginal: true)])
    }

    @Test func configInTheOldFormatIsKeptAsACopyBeforeTheFirstNewWrite() throws {
        defer { temp.remove() }
        let old = #"{"schemaVersion":1,"destinations":[],"sources":[{"id":"3A907808-6476-4794-85A6-52CECF2B501F","name":"Obsidian","slug":"obsidian","kind":{"folder":{"path":"~/Obsidian","excludes":[]}},"schedule":"daily","retention":{"daily":7,"weekly":4,"monthly":12,"yearly":0},"destinationIds":[],"instructions":"","enabled":true,"createdAt":"2026-09-30T10:00:00Z"}]}"#
        try temp.file("data/config.json", old)

        var config = try store.loadConfig()
        #expect(config.schemaVersion == 2)
        #expect(config.sources.first?.singleFolder?.path == "~/Obsidian")
        config.sources[0].description = "Notes"
        try store.saveConfig(config)
        try store.saveConfig(config)

        #expect(try String(contentsOf: temp.path("data/config.v1.json"), encoding: .utf8) == old)
        #expect(try store.loadConfig() == config)
        #expect(temp.names(in: "data") == ["config.json", "config.v1.json"])
    }

    @Test func stateWrittenByOlderVersionStillLoads() throws {
        defer { temp.remove() }
        let sourceId = UUID()
        try temp.file("data/state.json", """
        {"schemaVersion":1,"sources":{"\(sourceId.uuidString)":{"lastRun":"2026-09-28T10:00:00Z"}},"destinations":{},"debts":[],"lastReminders":{}}
        """)
        let state = try store.loadState()
        #expect(state.sourceState(sourceId).lastRun == Fixtures.date("2026-09-28 10:00:00"))
        #expect(state.lastDelivered.isEmpty)
        #expect(temp.names(in: "data") == ["state.json"])
    }
}
