import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct EditorSessionTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func source(_ name: String) -> Source {
        Source(name: name, slug: name.lowercased(), steps: [.folder("~/\(name)")], schedule: .daily, createdAt: now)
    }

    @Test func opensTheItemChosenLastTime() {
        let notes = source("Notes")
        let photos = source("Photos")
        var session = EditorSession<SourceDraft>()
        session.appear(remembered: photos.id, in: [notes, photos])
        #expect(session.selection == photos.id)
    }

    @Test func opensTheFirstItemWhenTheRememberedOneIsGone() {
        let notes = source("Notes")
        var session = EditorSession<SourceDraft>()
        session.appear(remembered: UUID(), in: [notes])
        #expect(session.selection == notes.id)
        session.appear(remembered: nil, in: [])
        #expect(session.selection == nil)
    }

    @Test func selectingAnItemOpensItsSavedVersionAndIsRemembered() {
        let notes = source("Notes")
        var session = EditorSession<SourceDraft>()
        session.start(SourceDraft(source("New")))
        #expect(session.selectionChanged(to: notes.id, in: [notes]) == notes.id)
        #expect(session.draft?.build() == notes)
        #expect(!session.isNew)
    }

    @Test func clearedOrUnknownSelectionKeepsWhatIsOpen() {
        let notes = source("Notes")
        var session = EditorSession<SourceDraft>()
        session.start(SourceDraft(notes))
        #expect(session.selectionChanged(to: nil, in: [notes]) == nil)
        #expect(session.selectionChanged(to: UUID(), in: [notes]) == nil)
        #expect(session.isNew)
        #expect(session.draft?.id == notes.id)
    }

    @Test func newItemIsShownWithoutSelectingAnythingInTheList() {
        let notes = source("Notes")
        var session = EditorSession<SourceDraft>()
        session.appear(remembered: notes.id, in: [notes])
        session.start(SourceDraft(source("New")))
        #expect(session.selection == nil)
        #expect(session.isNew)
        #expect(session.draft?.build().name == "New")
    }

    @Test func savedItemStaysOpenAndSelected() {
        let new = source("New")
        var session = EditorSession<SourceDraft>()
        session.start(SourceDraft(new))
        session.saved(new)
        #expect(!session.isNew)
        #expect(session.selection == new.id)
        #expect(session.draft?.hasChanges == false)
    }

    @Test func cancelBringsBackTheSavedVersion() {
        let notes = source("Notes")
        var session = EditorSession<SourceDraft>()
        _ = session.selectionChanged(to: notes.id, in: [notes])
        session.draft?.schedule = .monthly
        session.cancel(in: [notes])
        #expect(session.draft?.build() == notes)
        #expect(!session.isNew)
    }

    @Test func cancellingANewItemDropsItAndShowsTheFirstOne() {
        let notes = source("Notes")
        var session = EditorSession<SourceDraft>()
        session.start(SourceDraft(source("New")))
        session.cancel(in: [notes])
        #expect(!session.isNew)
        #expect(session.draft?.id == notes.id)
        #expect(session.selection == notes.id)
    }

    @Test func cancelOnAnItemDeletedMeanwhileShowsTheFirstOne() {
        let notes = source("Notes")
        let gone = source("Gone")
        var session = EditorSession<SourceDraft>()
        _ = session.selectionChanged(to: gone.id, in: [gone])
        session.cancel(in: [notes])
        #expect(session.draft?.id == notes.id)
    }

    @Test func afterTheLastItemIsDeletedNothingIsShown() {
        var session = EditorSession<DestinationDraft>()
        let disk = Destination(name: "HDD", kind: .localFolder(path: "/Volumes/HDD"))
        _ = session.selectionChanged(to: disk.id, in: [disk])
        session.showFirst(of: [])
        #expect(session.draft == nil)
        #expect(session.selection == nil)
    }

    @Test func destinationsAreEditedTheSameWay() {
        let disk = Destination(name: "HDD", kind: .localFolder(path: "/Volumes/HDD"))
        var session = EditorSession<DestinationDraft>()
        session.appear(remembered: nil, in: [disk])
        #expect(session.selectionChanged(to: session.selection, in: [disk]) == disk.id)
        session.draft?.isPeriodic = true
        #expect(session.draft?.hasChanges == true)
        session.cancel(in: [disk])
        #expect(session.draft?.build() == disk)
    }
}
