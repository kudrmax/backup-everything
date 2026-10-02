import Foundation
import Testing
@testable import BackupCore

struct LocalFolderDestinationTests {
    private let temp: TempDirectory
    private let destination: LocalFolderDestination
    private let date = Fixtures.date("2026-09-28 14:30:00")
    private let name = "2026-09-28_143000"

    init() throws {
        temp = try TempDirectory()
        try temp.directory("disk")
        try temp.directory("Trash")
        let trashFolder = temp.path("Trash")
        destination = LocalFolderDestination(root: temp.path("disk"), naming: Fixtures.naming) { url in
            try FileManager.default.moveItem(at: url, to: trashFolder.appendingPathComponent(url.lastPathComponent))
        }
    }

    private func manifest() -> SnapshotManifest {
        SnapshotManifest(sourceId: UUID(), sourceName: "Obsidian", collectedAt: date, fileCount: 2, totalBytes: 10)
    }

    private func vaultPayload() throws -> Payload {
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/sub/b.md", "beta")
        try temp.directory("vault/empty")
        return Payload(root: temp.path("vault"), collectedAt: date)
    }

    @Test func writesFilesAsIsWithManifestLast() async throws {
        defer { temp.remove() }
        try await destination.write(try vaultPayload(), manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)

        #expect(try String(contentsOf: temp.path("disk/obsidian/\(name)/sub/b.md"), encoding: .utf8) == "beta")
        #expect(temp.exists("disk/obsidian/\(name)/empty"))
        let stored = try JSONCoding.decoder().decode(
            SnapshotManifest.self,
            from: Data(contentsOf: temp.path("disk/obsidian/\(name)/_snapshot.json"))
        )
        #expect(stored.fileCount == 2)
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian") == [Snapshot(name: name, date: date)])
    }

    @Test func writesSingleFilePayload() async throws {
        defer { temp.remove() }
        let file = try temp.file("export.csv", "1;2")
        try await destination.write(Payload(root: file, collectedAt: date), manifest: manifest(), sourceSlug: "finance", snapshotName: name, reusingStoredFiles: true)
        #expect(temp.names(in: "disk/finance/\(name)") == ["_snapshot.json", "export.csv"])
    }

    @Test func onlyUnfinishedCopiesOfThisAppGoToTheTrash() async throws {
        defer { temp.remove() }
        try temp.file("disk/obsidian/2026-09-26_100000/a.md")
        try temp.file("disk/obsidian/2026-09-26_100000/_unfinished")
        try temp.file("disk/obsidian/2026-09-27_100000/a.md")
        try temp.file("disk/obsidian/Мои заметки/keep.md")
        try temp.file("disk/obsidian/notes.txt")

        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").isEmpty)
        try await destination.removeIncomplete(sourceSlug: "obsidian")
        #expect(temp.names(in: "disk/obsidian") == ["2026-09-27_100000", "notes.txt", "Мои заметки"])
        #expect(temp.names(in: "Trash") == ["2026-09-26_100000"])
    }

    @Test func finishedCopyKeepsNoUnfinishedMark() async throws {
        defer { temp.remove() }
        try await destination.write(try vaultPayload(), manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)
        #expect(!temp.exists("disk/obsidian/\(name)/_unfinished"))
        try await destination.removeIncomplete(sourceSlug: "obsidian")
        #expect(temp.names(in: "Trash").isEmpty)
    }

    @Test func unfinishedCopyUnderTheSameNameIsReplaced() async throws {
        defer { temp.remove() }
        try temp.file("disk/obsidian/\(name)/half.md")
        try temp.file("disk/obsidian/\(name)/_unfinished")

        try await destination.write(try vaultPayload(), manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)

        #expect(!temp.exists("disk/obsidian/\(name)/half.md"))
        #expect(temp.exists("disk/obsidian/\(name)/sub/b.md"))
        #expect(temp.names(in: "Trash") == [name])
    }

    @Test func foreignFolderUnderTheSameNameIsLeftAlone() async throws {
        defer { temp.remove() }
        try temp.file("disk/obsidian/\(name)/mine.md")
        let payload = try vaultPayload()

        await #expect(throws: DestinationError.folderInTheWay(temp.path("disk/obsidian/\(name)").path)) {
            try await destination.write(payload, manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)
        }
        #expect(temp.names(in: "disk/obsidian/\(name)") == ["mine.md"])
    }

    @Test func missingRootIsUnavailableAndNeverCreated() async throws {
        defer { temp.remove() }
        let unplugged = LocalFolderDestination(root: temp.path("Volumes/HDD/Backups"), naming: Fixtures.naming)
        #expect(await unplugged.isAvailable() == false)
        let payload = try vaultPayload()
        await #expect(throws: DestinationError.unavailable) {
            try await unplugged.write(payload, manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)
        }
        #expect(!temp.exists("Volumes"))
        #expect(try await unplugged.listSnapshots(sourceSlug: "obsidian").isEmpty)
    }

    @Test func deletesOnlySnapshotDirectories() async throws {
        defer { temp.remove() }
        try await destination.write(try vaultPayload(), manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)
        try temp.file("disk/obsidian/Photos/keep.jpg")

        try await destination.delete(Snapshot(name: "Photos", date: date), sourceSlug: "obsidian")
        #expect(temp.exists("disk/obsidian/Photos/keep.jpg"))

        try await destination.delete(Snapshot(name: name, date: date), sourceSlug: "obsidian")
        #expect(temp.names(in: "disk/obsidian") == ["Photos"])
    }

    @Test func failedWriteLeavesNoManifest() async throws {
        defer { temp.remove() }
        let payload = Payload(root: temp.path("missing-source"), collectedAt: date)
        await #expect(throws: SourceError.pathMissing(temp.path("missing-source").path)) {
            try await destination.write(payload, manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)
        }
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").isEmpty)
        #expect(temp.names(in: "disk/obsidian/\(name)") == ["_unfinished"])
        try await destination.removeIncomplete(sourceSlug: "obsidian")
        #expect(temp.names(in: "disk/obsidian").isEmpty)
        #expect(temp.names(in: "Trash") == [name])
    }

    @Test func usedBytesSumsEverythingUnderRoot() async throws {
        defer { temp.remove() }
        try temp.file("disk/obsidian/\(name)/a.md", "alpha")
        try temp.file("disk/obsidian/\(name)/sub/b.md", "abc")
        let files = ["disk/obsidian/\(name)/a.md", "disk/obsidian/\(name)/sub/b.md"]
        #expect(try await destination.usedBytes() == temp.allocatedBytes(files[0], files[1]))
    }

    private func storedManifest(_ slug: String = "obsidian", _ snapshotName: String? = nil) throws -> SnapshotManifest {
        try JSONCoding.decoder().decode(
            SnapshotManifest.self,
            from: Data(contentsOf: temp.path("disk/\(slug)/\(snapshotName ?? name)/_snapshot.json"))
        )
    }

    private func destination(trash: @escaping ManualExportInbox.Trash) -> LocalFolderDestination {
        LocalFolderDestination(root: temp.path("disk"), naming: Fixtures.naming, trash: trash)
    }

    @Test func symbolicLinksAreCopiedAsLinksEvenWhenBroken() async throws {
        defer { temp.remove() }
        let payload = try vaultPayload()
        let fileManager = FileManager.default
        try fileManager.createSymbolicLink(atPath: temp.path("vault/sub/link.md").path, withDestinationPath: "../a.md")
        try fileManager.createSymbolicLink(atPath: temp.path("vault/gone.md").path, withDestinationPath: "/nonexistent/target.md")

        try await destination.write(payload, manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)

        let copy = temp.path("disk/obsidian/\(name)")
        #expect(try fileManager.destinationOfSymbolicLink(atPath: copy.appendingPathComponent("sub/link.md").path) == "../a.md")
        #expect(try fileManager.destinationOfSymbolicLink(atPath: copy.appendingPathComponent("gone.md").path) == "/nonexistent/target.md")
        #expect(try String(contentsOf: copy.appendingPathComponent("sub/link.md"), encoding: .utf8) == "alpha")
        #expect(try storedManifest().files?.map(\.path) == ["a.md", "sub/b.md"])
    }

    @Test func namesWithSpacesAndSymbolsArriveIntact() async throws {
        defer { temp.remove() }
        let odd = ["My notes/2026 plan (final).md", "émoji 🙂/#1 & 'quotes'.txt", "  leading space.md", "Мои заметки/План на год.md"]
        for (index, path) in odd.enumerated() { try temp.file("vault/\(path)", "content \(index)") }

        try await destination.write(
            Payload(root: temp.path("vault"), collectedAt: date),
            manifest: manifest(),
            sourceSlug: "obsidian",
            snapshotName: name,
            reusingStoredFiles: true
        )

        for (index, path) in odd.enumerated() {
            #expect(try String(contentsOf: temp.path("disk/obsidian/\(name)/\(path)"), encoding: .utf8) == "content \(index)")
        }
        #expect(try Set(storedManifest().files?.map(\.path) ?? []) == Set(odd))
    }

    @Test func copyWithManifestAndLeftoverMarkIsFinished() async throws {
        defer { temp.remove() }
        try await destination.write(try vaultPayload(), manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)
        try temp.file("disk/obsidian/\(name)/_unfinished")

        #expect(try await destination.listSnapshots(sourceSlug: "obsidian") == [Snapshot(name: name, date: date)])
        try await destination.removeIncomplete(sourceSlug: "obsidian")
        #expect(temp.names(in: "Trash").isEmpty)
        #expect(temp.exists("disk/obsidian/\(name)/sub/b.md"))
    }

    @Test func finishedCopyUnderTheSameNameIsNeverOverwritten() async throws {
        defer { temp.remove() }
        try await destination.write(try vaultPayload(), manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)
        let payload = try vaultPayload()
        try temp.file("vault/a.md", "changed")

        await #expect(throws: DestinationError.folderInTheWay(temp.path("disk/obsidian/\(name)").path)) {
            try await destination.write(payload, manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)
        }
        #expect(try String(contentsOf: temp.path("disk/obsidian/\(name)/a.md"), encoding: .utf8) == "alpha")
        #expect(temp.names(in: "Trash").isEmpty)
    }

    @Test func filesAndManifestlessFoldersWithSnapshotNamesAreNotCopies() async throws {
        defer { temp.remove() }
        try temp.file("disk/obsidian/2026-09-25_100000", "a file, not a folder")
        try temp.file("disk/obsidian/2026-09-26_100000/notes.md")
        try temp.file("disk/obsidian/2026-09-27_100000/_snapshot.json", "{}")

        let listed = try await destination.listSnapshots(sourceSlug: "obsidian").map(\.name)
        #expect(listed == ["2026-09-27_100000"])
        try await destination.removeIncomplete(sourceSlug: "obsidian")
        #expect(temp.names(in: "Trash").isEmpty)
        #expect(temp.names(in: "disk/obsidian") == ["2026-09-25_100000", "2026-09-26_100000", "2026-09-27_100000"])
    }

    @Test func unreadableFileStopsTheWriteAndLeavesAnUnfinishedCopyOnly() async throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temp.path("vault/sub/b.md").path)
            temp.remove()
        }
        let earlier = "2026-09-27_100000"
        try await destination.write(try vaultPayload(), manifest: manifest(), sourceSlug: "obsidian", snapshotName: earlier, reusingStoredFiles: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: temp.path("vault/sub/b.md").path)

        await #expect(throws: POSIXError(.EACCES)) {
            try await destination.write(
                Payload(root: temp.path("vault"), collectedAt: date),
                manifest: manifest(),
                sourceSlug: "obsidian",
                snapshotName: name,
                reusingStoredFiles: false
            )
        }

        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").map(\.name) == [earlier])
        #expect(temp.exists("disk/obsidian/\(name)/_unfinished"))
        #expect(!temp.exists("disk/obsidian/\(name)/_snapshot.json"))
        try await destination.removeIncomplete(sourceSlug: "obsidian")
        #expect(temp.names(in: "disk/obsidian") == [earlier])
        #expect(temp.exists("disk/obsidian/\(earlier)/sub/b.md"))
    }

    @Test func runningOutOfSpaceIsReportedAsSuch() async throws {
        defer { temp.remove() }
        let payload = try vaultPayload()
        for failure in [POSIXError(.ENOSPC), CocoaError(.fileWriteOutOfSpace)] as [Error] {
            try temp.file("disk/obsidian/\(name)/_unfinished")
            let full = destination { _ in throw failure }
            await #expect(throws: DestinationError.outOfSpace) {
                try await full.write(payload, manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)
            }
            #expect(try await full.listSnapshots(sourceSlug: "obsidian").isEmpty)
        }
    }

    @Test func otherTrashFailuresAreReportedAsTheyAre() async throws {
        defer { temp.remove() }
        try temp.file("disk/obsidian/\(name)/_unfinished")
        let payload = try vaultPayload()
        let locked = destination { _ in throw POSIXError(.EPERM) }
        await #expect(throws: POSIXError(.EPERM)) {
            try await locked.write(payload, manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)
        }
        await #expect(throws: POSIXError(.EPERM)) {
            try await locked.removeIncomplete(sourceSlug: "obsidian")
        }
        #expect(temp.exists("disk/obsidian/\(name)/_unfinished"))
    }

    @Test func unpluggedDiskCannotBeReadOrMeasured() async throws {
        defer { temp.remove() }
        let unplugged = LocalFolderDestination(root: temp.path("Volumes/HDD"), naming: Fixtures.naming)
        let snapshot = Snapshot(name: name, date: date)
        await #expect(throws: DestinationError.unavailable) {
            try await unplugged.materialize(snapshot, sourceSlug: "obsidian", scratch: temp.path("scratch"))
        }
        await #expect(throws: DestinationError.unavailable) {
            try await unplugged.usedBytes()
        }
        #expect(await unplugged.canShareUnchangedFiles() == nil)
        try await unplugged.removeIncomplete(sourceSlug: "obsidian")
        #expect(!temp.exists("Volumes"))
    }

    @Test func rootThatIsAFileOrReadOnlyIsUnavailable() async throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path("readonly").path)
            temp.remove()
        }
        try temp.file("plain-file")
        try temp.directory("readonly")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: temp.path("readonly").path)
        #expect(await LocalFolderDestination(root: temp.path("plain-file"), naming: Fixtures.naming).isAvailable() == false)
        #expect(await LocalFolderDestination(root: temp.path("readonly"), naming: Fixtures.naming).isAvailable() == false)
    }

    @Test func materializeHandsOutTheCopyInPlace() async throws {
        defer { temp.remove() }
        try await destination.write(try vaultPayload(), manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)
        let folder = try await destination.materialize(Snapshot(name: name, date: date), sourceSlug: "obsidian", scratch: temp.path("scratch"))
        #expect(folder.standardizedFileURL == temp.path("disk/obsidian/\(name)").standardizedFileURL)
        #expect(!temp.exists("scratch"))
    }

    @Test func deletingIsPermanentAndLeavesOtherCopies() async throws {
        defer { temp.remove() }
        let older = "2026-09-27_100000"
        try await destination.write(try vaultPayload(), manifest: manifest(), sourceSlug: "obsidian", snapshotName: older, reusingStoredFiles: true)
        try await destination.write(try vaultPayload(), manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)

        try await destination.delete(Snapshot(name: older, date: Fixtures.date("2026-09-27 10:00:00")), sourceSlug: "obsidian")

        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").map(\.name) == [name])
        #expect(temp.names(in: "Trash").isEmpty)
        #expect(try String(contentsOf: temp.path("disk/obsidian/\(name)/a.md"), encoding: .utf8) == "alpha")
    }
}
