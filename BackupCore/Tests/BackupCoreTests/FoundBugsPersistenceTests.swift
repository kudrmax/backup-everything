import Foundation
import Testing
@testable import BackupCore

/// Reproductions of bugs found in persistence and configuration. Each test describes the expected behaviour and fails today.
struct FoundBugsPersistenceTests {
    private let editor = ConfigEditor()

    @Test func runAppendedAfterAnInterruptedWriteIsNotLost() throws {
        let temp = try TempDirectory()
        defer { try? FileManager.default.trashItem(at: temp.url, resultingItemURL: nil) }
        let store = Store(dataDirectory: temp.path("data"))
        let start = Fixtures.date("2026-09-01 08:00:00")
        try store.appendRun(RunRecord(sourceId: UUID(), sourceName: "A", trigger: .manual, startedAt: start, finishedAt: start))
        let handle = try FileHandle(forWritingTo: temp.path("data/history/2026-09.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"id":"0E5B"#.utf8))
        try handle.close()

        try store.appendRun(RunRecord(sourceId: UUID(), sourceName: "B", trigger: .manual, startedAt: start.addingTimeInterval(60), finishedAt: start))

        #expect(store.loadRuns().map(\.sourceName) == ["B", "A"])
    }
}
