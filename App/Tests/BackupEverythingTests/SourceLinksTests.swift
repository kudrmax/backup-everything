import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct SourceLinksTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let laptop = Destination(name: "Папка на ноуте", kind: .localFolder(path: "~/Files/Backups"))
    private let cloud = Destination(name: "Google Drive", kind: .rclone(remote: "gdrive", path: "backups"))

    private func source(_ kind: SourceKind, to destinations: [Destination]) -> Source {
        Source(name: "Anki", slug: "anki", kind: kind, schedule: .weekly, destinationIds: destinations.map(\.id), createdAt: now)
    }

    @Test func onlyAFolderSourceHasAnOriginalToOpen() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(SourceLinks.original(of: source(.folder(path: "~/Anki", excludes: []), to: []))?.path == "\(home)/Anki")
        #expect(SourceLinks.original(of: source(.folder(path: "", excludes: []), to: [])) == nil)
        #expect(SourceLinks.original(of: source(.command(command: "true", timeoutSeconds: 60), to: [])) == nil)
        #expect(SourceLinks.original(of: source(.steps(steps: []), to: [])) == nil)
        #expect(SourceLinks.original(of: source(.manualExport(watchPath: "~/Downloads", filePattern: "*.csv", fileMode: .single, removeOriginal: true), to: [])) == nil)
    }

    @Test func copyOpensTheLatestDeliveredSnapshotOnLocalDestinations() {
        let anki = source(.folder(path: "~/Anki", excludes: []), to: [laptop, cloud])
        let config = Config(sources: [anki], destinations: [laptop, cloud])
        var state = AppState()
        #expect(SourceLinks.copies(of: anki, config: config, state: state) == [
            CopyPlace(destination: laptop, folder: nil, unavailableReason: "Копий ещё нет"),
            CopyPlace(destination: cloud, folder: nil, unavailableReason: "Копия в облаке — в Finder не открыть"),
        ])

        state.lastDelivered[AppState.deliveryKey(sourceId: anki.id, destinationId: laptop.id)] = "2026-10-01_012056"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(SourceLinks.copies(of: anki, config: config, state: state).first?.folder?.path == "\(home)/Files/Backups/anki/2026-10-01_012056")
    }
}
