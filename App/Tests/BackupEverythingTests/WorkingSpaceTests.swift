import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct WorkingSpaceTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func source(_ name: String, _ steps: [SourceStep], enabled: Bool = true) -> Source {
        var source = Source(name: name, slug: name.lowercased(), steps: steps, schedule: .weekly, createdAt: now)
        source.enabled = enabled
        return source
    }

    @Test func backupsRunOneAtATimeSoTheLargestStagedOneCountsPlusWhatWaitsForADisk() {
        let obsidian = source("Obsidian", [.folder("~/Obsidian")])
        let github = source("GitHub", [.command("gh", timeoutSeconds: 60)])
        let pocketBook = source("PocketBook", [.device(""), .folder("/Volumes/PB")])
        let off = source("Off", [.command("x", timeoutSeconds: 60)], enabled: false)
        let need = WorkingSpace.need(
            sources: [obsidian, github, pocketBook, off],
            lastSizes: [obsidian.id: 9_000, github.id: 300, pocketBook.id: 2_400, off.id: 99_999],
            waiting: [github.id: 50]
        )
        #expect(need.largest?.name == "PocketBook")
        #expect(need.bytes == 2_450)
    }

    @Test func packageOfTheLargestSourceIsNotCountedTwice() {
        let pocketBook = source("PocketBook", [.device(""), .folder("/Volumes/PB")])
        let need = WorkingSpace.need(sources: [pocketBook], lastSizes: [pocketBook.id: 2_400], waiting: [pocketBook.id: 2_400])
        #expect(need.bytes == 2_400)
    }

    @Test func packageWaitingForADiskCountsEvenWithoutAKnownSizeOfItsSource() {
        let pocketBook = source("PocketBook", [.device(""), .folder("/Volumes/PB")])
        let need = WorkingSpace.need(sources: [pocketBook], lastSizes: [:], waiting: [pocketBook.id: 2_400])
        #expect(need.bytes == 2_400)
        #expect(need.largest == nil)
        #expect(need.waitingBytes == 2_400)
    }
}
