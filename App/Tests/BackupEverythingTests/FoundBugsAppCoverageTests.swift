import BackupCore
import Foundation
import Testing
@testable import BackupEverything

/// Bugs found while raising test coverage. These tests describe the expected behaviour and fail until the bugs are fixed.
@MainActor
struct FoundBugsAppCoverageTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// SourcesView.save and DestinationsView.save mark the draft as saved whatever happened:
    /// AppModel.save gives no result, so a failed write hides the Save bar and the edits are lost on the next click.
    @Test func failedSaveKeepsTheEditsWaitingToBeSaved() async throws {
        let fixture = try ModelFixture()
        let saved = try #require(fixture.model.config.sources.first)
        var session = EditorSession<SourceDraft>()
        _ = session.selectionChanged(to: saved.id, in: fixture.model.config.sources)
        session.draft?.schedule = .monthly
        let edited = try #require(session.draft?.build())
        try Data("{ damaged".utf8).write(to: fixture.store.configURL)

        await fixture.model.save(edited)
        session.saved(edited)

        #expect(fixture.model.problem != nil)
        #expect(fixture.model.config.source(saved.id)?.schedule == saved.schedule)
        #expect(session.draft?.hasChanges == true, "the Save bar disappears although nothing was saved")
    }

    @Test func failedAddKeepsTheNewSourceOfferedForAdding() async throws {
        let fixture = try ModelFixture()
        var session = EditorSession<SourceDraft>()
        var new = fixture.model.newSource(from: nil)
        new.name = "Notes"
        new.steps = [.folder("~/Notes")]
        session.start(SourceDraft(new))
        try Data("{ damaged".utf8).write(to: fixture.store.configURL)

        await fixture.model.save(new)
        session.saved(new)

        #expect(fixture.model.config.source(new.id) == nil)
        #expect(session.isNew, "the editor shows the source as added although it is not in the settings")
    }

    /// WorkingSpace.need leaves out the package of the source it picked as the largest, counting that source’s last size instead.
    /// When that size is unknown (its run fell out of the last 300 loaded, or the record has no size), the waiting package is not counted at all.
    @Test func packageWaitingForADiskCountsEvenWithoutAKnownSizeOfItsSource() {
        let pocketBook = Source(name: "PocketBook", slug: "pocketbook", steps: [.device(""), .folder("/Volumes/PB")], schedule: .monthly, createdAt: now)
        let need = WorkingSpace.need(sources: [pocketBook], lastSizes: [:], waiting: [pocketBook.id: 2_400])
        #expect(need.bytes == 2_400)
    }
}
