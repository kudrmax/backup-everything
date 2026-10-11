import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct SourceLinksTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let laptop = Destination(name: "Laptop folder", kind: .localFolder(path: "~/Files/Backups"))
    private let disk = Destination(name: "HDD", kind: .localFolder(path: "/Volumes/TEST-BE-A/Backups"))

    private func source(_ steps: [SourceStep], to destinations: [Destination]) -> Source {
        Source(name: "Anki", slug: "anki", steps: steps, schedule: .weekly, destinationIds: destinations.map(\.id), createdAt: now)
    }

    @Test func originalIsTheFirstFolderTheSourceCopies() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(SourceLinks.original(of: source([.folder("~/Anki")], to: []))?.path == "\(home)/Anki")
        #expect(SourceLinks.original(of: source([.device("/Volumes/PB"), .folder("/Volumes/PB/Books")], to: []))?.path == "/Volumes/PB/Books")
        #expect(SourceLinks.original(of: source([.folder("")], to: [])) == nil)
        #expect(SourceLinks.original(of: source([.command("true", timeoutSeconds: 60)], to: [])) == nil)
        #expect(SourceLinks.original(of: source([.file("*.csv", in: "~/Downloads")], to: [])) == nil)
    }

    @Test func copyOpensTheNewestCopySeenOnEachDestination() {
        let anki = source([.folder("~/Anki")], to: [laptop, disk])
        let config = Config(sources: [anki], destinations: [laptop, disk])
        var state = AppState()
        #expect(SourceLinks.copies(of: anki, config: config, state: state) == [
            CopyPlace(destination: laptop, folder: nil, unavailableReason: "No copies yet"),
            CopyPlace(destination: disk, folder: nil, unavailableReason: "No copies yet"),
        ])

        let older = Snapshot(name: "2026-09-30_012056", date: now.addingTimeInterval(-86_400))
        let newer = Snapshot(name: "2026-10-01_012056", date: now)
        state.recordCopies(sourceId: anki.id, destinationId: laptop.id, [newer, older], seenAt: now)
        state.recordCopies(sourceId: anki.id, destinationId: disk.id, [older], seenAt: now)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(SourceLinks.copies(of: anki, config: config, state: state).map(\.folder?.path) == [
            "\(home)/Files/Backups/anki/2026-10-01_012056",
            "/Volumes/TEST-BE-A/Backups/anki/2026-09-30_012056",
        ])
    }
}
