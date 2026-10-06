import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct SourceLinksTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let laptop = Destination(name: "Laptop folder", kind: .localFolder(path: "~/Files/Backups"))
    private let cloud = Destination(name: "Google Drive", kind: .rclone(remote: "gdrive", path: "backups"))

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

    @Test func copyOpensTheLatestDeliveredSnapshotOnLocalDestinations() {
        let anki = source([.folder("~/Anki")], to: [laptop, cloud])
        let config = Config(sources: [anki], destinations: [laptop, cloud])
        var state = AppState()
        #expect(SourceLinks.copies(of: anki, config: config, state: state) == [
            CopyPlace(destination: laptop, folder: nil, unavailableReason: "No copies yet"),
            CopyPlace(destination: cloud, folder: nil, unavailableReason: "The copy is in the cloud and can’t be opened in Finder"),
        ])

        state.lastDelivered[AppState.deliveryKey(sourceId: anki.id, destinationId: laptop.id)] = "2026-10-01_012056"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(SourceLinks.copies(of: anki, config: config, state: state).first?.folder?.path == "\(home)/Files/Backups/anki/2026-10-01_012056")
    }

    /// A folder of the same path on another disk, or on no disk at all, is not the copy.
    @Test(arguments: [
        (DiskCheck.notConnected, "The disk isn’t connected"),
        (.notConfirmed(connected: nil), "The disk isn’t confirmed"),
        (.otherDisk(DiskIdentity(uuid: "22222222-BBBB-4BBB-8BBB-222222222222", name: "TEST-BE-B")), "Another disk is connected"),
        (.unidentified(name: "TEST-BE-B"), "The disk’s ID can’t be read"),
        (.unsupportedFormat(name: "TEST-BE-B", format: "exFAT"), "The disk is formatted as exFAT, not APFS"),
    ])
    func copyOnADiskThatIsNotConfirmedHereCannotBeOpened(check: DiskCheck, reason: String) {
        let disk = Destination(name: "HDD", kind: .localFolder(path: "/Volumes/TEST-BE-A/Backups"))
        let anki = source([.folder("~/Anki")], to: [disk])
        var state = AppState()
        state.lastDelivered[AppState.deliveryKey(sourceId: anki.id, destinationId: disk.id)] = "2026-10-01_012056"
        let config = Config(sources: [anki], destinations: [disk])

        #expect(SourceLinks.copies(of: anki, config: config, state: state, disks: [disk.id: check]) == [
            CopyPlace(destination: disk, folder: nil, unavailableReason: reason),
        ])
        #expect(SourceLinks.copies(of: anki, config: config, state: state, disks: [disk.id: .confirmed]).first?.folder != nil)
    }
}
