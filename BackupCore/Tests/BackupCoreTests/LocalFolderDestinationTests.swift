import Darwin
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

    @Test func sourceThatCannotBeReadStartsNoCopy() async throws {
        defer { temp.remove() }
        let payload = Payload(root: temp.path("missing-source"), collectedAt: date)
        await #expect(throws: SourceError.pathMissing(temp.path("missing-source").path)) {
            try await destination.write(payload, manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)
        }
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").isEmpty)
        #expect(!temp.exists("disk/obsidian/\(name)"))
    }

    @Test func usedBytesSumsEverythingUnderRoot() async throws {
        defer { temp.remove() }
        try temp.file("disk/obsidian/\(name)/a.md", "alpha")
        try temp.file("disk/obsidian/\(name)/sub/b.md", "abc")
        try temp.file("disk/obsidian/\(name)/sub/._c.md", String(repeating: "c", count: 10_000))
        let files = ["disk/obsidian/\(name)/a.md", "disk/obsidian/\(name)/sub/b.md", "disk/obsidian/\(name)/sub/._c.md"]
        #expect(try await destination.usedBytes() == temp.allocatedBytes(files[0], files[1], files[2]))
    }

    /// The size is an estimate for showing: a folder that cannot be read is left out, not the whole measurement.
    @Test func usedBytesLeavesOutFoldersThatCannotBeRead() async throws {
        defer {
            Permissions.unlockTree(temp.url)
            temp.remove()
        }
        try temp.file("disk/obsidian/\(name)/a.md", "alpha")
        try temp.file("disk/obsidian/closed/b.md", "beta")
        #expect(chmod(temp.path("disk/obsidian/closed").path, 0o000) == 0)
        #expect(try await destination.usedBytes() == temp.allocatedBytes("disk/obsidian/\(name)/a.md"))
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

    // MARK: The written copy is checked before it is finished

    /// Writes the vault while `meddle` changes the copy of `relativePath` right after it is written.
    private func expectUnfinished(
        _ error: (String) -> DestinationError,
        at relativePath: String,
        meddle: @escaping @Sendable (String) -> Void
    ) async throws {
        let payload = try vaultPayload()
        try FileManager.default.createSymbolicLink(atPath: temp.path("vault/sub/link.md").path, withDestinationPath: "../a.md")
        let copy = temp.path("disk/obsidian/\(name)").path
        var meddling = destination
        meddling.afterWritingItem = { path in
            if path == copy + "/" + relativePath { meddle(path) }
        }

        await #expect(throws: error(copy + "/" + relativePath)) {
            try await meddling.write(payload, manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)
        }
        #expect(temp.exists("disk/obsidian/\(name)/_unfinished"))
        #expect(!temp.exists("disk/obsidian/\(name)/_snapshot.json"))
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").isEmpty)
    }

    @Test func fileGoneFromTheCopyLeavesItUnfinished() async throws {
        defer { temp.remove() }
        try await expectUnfinished(DestinationError.missingFromCopy, at: "a.md") { unlink($0) }
    }

    @Test func fileShortenedInTheCopyLeavesItUnfinished() async throws {
        defer { temp.remove() }
        try await expectUnfinished(DestinationError.changedInCopy, at: "sub/b.md") { truncate($0, 1) }
    }

    @Test func linkPointedElsewhereInTheCopyLeavesItUnfinished() async throws {
        defer { temp.remove() }
        try await expectUnfinished(DestinationError.changedInCopy, at: "sub/link.md") { path in
            unlink(path)
            symlink("b.md", path)
        }
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

    // MARK: Locks, permissions and access lists kept from the originals

    private func cleanUp() {
        Permissions.unlockTree(temp.url)
        temp.remove()
    }

    private func write(_ root: String, as snapshotName: String? = nil) async throws {
        try await destination.write(
            Payload(root: temp.path(root), collectedAt: date),
            manifest: manifest(),
            sourceSlug: "obsidian",
            snapshotName: snapshotName ?? name,
            reusingStoredFiles: false
        )
    }

    private func permissions(_ relative: String) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: temp.path(relative).path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func denyDeleting(_ relative: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone deny delete,delete_child", temp.path(relative).path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func copyWithLockedFilesIsDeletedWhole() async throws {
        defer { cleanUp() }
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/m.md", "middle")
        try temp.file("vault/z.md", "omega")
        try Permissions.lock(temp.path("vault/m.md"))
        try await write("vault")

        try await destination.delete(Snapshot(name: name, date: date), sourceSlug: "obsidian")

        #expect(temp.names(in: "disk/obsidian").isEmpty)
    }

    @Test func copyWithLockedReadOnlyAndProtectedFoldersIsDeletedWhole() async throws {
        defer { cleanUp() }
        try temp.file("vault/locked/a.md", "alpha")
        try temp.file("vault/readonly/inner/b.md", "beta")
        try temp.file("vault/protected/c.md", "gamma")
        try Permissions.lock(temp.path("vault/locked"))
        chmod(temp.path("vault/readonly/inner").path, 0o500)
        chmod(temp.path("vault/readonly").path, 0o500)
        try denyDeleting("vault/protected")
        try denyDeleting("vault/protected/c.md")
        try await write("vault")
        #expect(try permissions("disk/obsidian/\(name)/readonly") == 0o500)

        try await destination.delete(Snapshot(name: name, date: date), sourceSlug: "obsidian")

        #expect(temp.names(in: "disk/obsidian").isEmpty)
    }

    @Test func lockedCopyFolderIsDeletedToo() async throws {
        defer { cleanUp() }
        try temp.file("vault/a.md", "alpha")
        try await write("vault")
        try Permissions.lock(temp.path("disk/obsidian/\(name)"))

        try await destination.delete(Snapshot(name: name, date: date), sourceSlug: "obsidian")

        #expect(temp.names(in: "disk/obsidian").isEmpty)
    }

    @Test func deletionThatStoppedHalfwayIsNeverTakenForACopyAndIsFinishedLater() async throws {
        defer { cleanUp() }
        let interrupted = "2026-09-27_100000.deleting"
        try temp.file("disk/obsidian/\(interrupted)/_snapshot.json", "{}")
        try temp.file("disk/obsidian/\(interrupted)/locked.md", "half deleted")
        try Permissions.lock(temp.path("disk/obsidian/\(interrupted)/locked.md"))
        try temp.file("disk/obsidian/notes.deleting/keep.md")

        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").isEmpty)
        try await destination.removeIncomplete(sourceSlug: "obsidian")

        #expect(temp.names(in: "disk/obsidian") == ["notes.deleting"])
        #expect(temp.names(in: "Trash").isEmpty)
    }

    /// A deletion that cannot be finished is reported every time, not once: the copy keeps taking space.
    @Test func deletionThatStillCannotBeFinishedIsReportedAfterTheRest() async throws {
        let personal = try temp.file("Documents/contract.pdf", "signed")
        defer {
            try? Permissions.dropAccessList(personal)
            cleanUp()
        }
        try Permissions.denyDeleting(personal)
        let stuck = try temp.directory("disk/obsidian/2026-09-26_100000.deleting")
        #expect(Darwin.link(personal.path, stuck.appendingPathComponent("contract.pdf").path) == 0)
        try temp.file("disk/obsidian/2026-09-27_100000.deleting/old.md")

        let error = await #expect(throws: DestinationError.self) {
            try await destination.removeIncomplete(sourceSlug: "obsidian")
        }

        guard case let .unfinishedDeletions(problems)? = error else { return }
        #expect(problems.count == 1)
        #expect(problems.first?.contains("2026-09-26_100000.deleting/contract.pdf” is another name (a hard link)") == true)
        #expect(temp.names(in: "disk/obsidian") == ["2026-09-26_100000.deleting"])
    }

    @Test func copyIsDeletedAgainAfterItWasRestoredUnderTheSameName() async throws {
        defer { cleanUp() }
        try temp.file("vault/a.md", "alpha")
        try temp.file("disk/obsidian/\(name).deleting/old.md", "left from the first deletion")
        try await write("vault")

        try await destination.delete(Snapshot(name: name, date: date), sourceSlug: "obsidian")

        #expect(temp.names(in: "disk/obsidian").isEmpty)
    }

    @Test func deletingACopyThatIsGoneIsAnError() async throws {
        defer { temp.remove() }
        await #expect(throws: POSIXError(.ENOENT)) {
            try await destination.delete(Snapshot(name: name, date: date), sourceSlug: "obsidian")
        }
    }

    // MARK: Everything in the source or nothing

    @Test func unreadableSubfolderStartsNoCopy() async throws {
        defer { cleanUp() }
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/private/diary.md", "secret")
        chmod(temp.path("vault/private").path, 0)

        await #expect(throws: SourceError.unreadable(temp.path("vault/private").path)) {
            try await write("vault")
        }
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").isEmpty)
        #expect(!temp.exists("disk/obsidian/\(name)"))
    }

    @Test func singleFileGivenAsALinkIsStoredWithItsData() async throws {
        defer { temp.remove() }
        let real = try temp.file("dotfiles/zshrc", "export PATH=/opt/homebrew/bin")
        try temp.directory("home")
        try FileManager.default.createSymbolicLink(at: temp.path("home/.zshrc"), withDestinationURL: real)

        try await write("home/.zshrc")

        let stored = temp.path("disk/obsidian/\(name)/.zshrc")
        #expect(try FileManager.default.attributesOfItem(atPath: stored.path)[.type] as? FileAttributeType == .typeRegular)
        #expect(try String(contentsOf: stored, encoding: .utf8) == "export PATH=/opt/homebrew/bin")
        #expect(try storedManifest().files?.map(\.path) == [".zshrc"])
    }

    @Test func folderGivenAsALinkIsStoredWithItsContents() async throws {
        defer { temp.remove() }
        try temp.file("real/a.md", "alpha")
        try FileManager.default.createSymbolicLink(at: temp.path("vault"), withDestinationURL: temp.path("real"))

        try await write("vault")

        #expect(try String(contentsOf: temp.path("disk/obsidian/\(name)/a.md"), encoding: .utf8) == "alpha")
    }

    @Test func foldersKeepTheirPermissionsDatesAndAttributes() async throws {
        defer { cleanUp() }
        let modified = Fixtures.date("2026-01-02 03:04:05")
        try temp.file("vault/keys/id_ed25519", "PRIVATE")
        try temp.file("vault/keys/sub/known_hosts", "github.com")
        try Permissions.setAttribute("com.apple.metadata:_kMDItemUserTags", value: "Red", on: temp.path("vault/keys"))
        chmod(temp.path("vault/keys/sub").path, 0o500)
        chmod(temp.path("vault/keys").path, 0o700)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: temp.path("vault/keys").path)

        try await write("vault")

        let keys = "disk/obsidian/\(name)/keys"
        #expect(try permissions(keys) == 0o700)
        #expect(try permissions(keys + "/sub") == 0o500)
        #expect(try String(contentsOf: temp.path(keys + "/sub/known_hosts"), encoding: .utf8) == "github.com")
        #expect(try FileManager.default.attributesOfItem(atPath: temp.path(keys).path)[.modificationDate] as? Date == modified)
        #expect(try Permissions.attribute("com.apple.metadata:_kMDItemUserTags", of: temp.path(keys)) == "Red")
    }

    // MARK: Names of the app's own files in the person's data

    @Test func dataNamedLikeTheAppsOwnFilesAtTheTopIsRefused() async throws {
        defer { temp.remove() }
        for (index, reserved) in ["_snapshot.json", "_Unfinished", "_SNAPSHOT.JSON"].enumerated() {
            try temp.file("vault\(index)/a.md", "alpha")
            try temp.file("vault\(index)/\(reserved)", "exported by another tool")

            await #expect(throws: SourceError.reservedName(reserved)) {
                try await write("vault\(index)")
            }
        }
        #expect(temp.names(in: "disk").isEmpty)
    }

    @Test func halfWrittenCopyOfDataWithItsOwnManifestNeverCountsAsFinished() async throws {
        defer { cleanUp() }
        try temp.file("vault/_snapshot.json", "{\"note\": \"exported by another tool\"}")
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/zz.md", "unreadable")
        chmod(temp.path("vault/zz.md").path, 0)

        await #expect(throws: (any Error).self) {
            try await write("vault")
        }
        chmod(temp.path("vault/zz.md").path, 0o644)

        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").isEmpty)
        try await destination.removeIncomplete(sourceSlug: "obsidian")
        #expect(!temp.exists("disk/obsidian/\(name)"))
    }

    @Test func dataNamedLikeTheAppsOwnFilesDeeperIsCopied() async throws {
        defer { temp.remove() }
        try temp.file("vault/site/_snapshot.json", "{\"page\": 1}")
        try temp.file("vault/draft/_unfinished", "todo")

        try await write("vault")

        #expect(try await destination.listSnapshots(sourceSlug: "obsidian") == [Snapshot(name: name, date: date)])
        #expect(try storedManifest().files?.map(\.path) == ["draft/_unfinished", "site/_snapshot.json"])
    }

    // MARK: Listing

    @Test func unreadableFolderOfTheSourceIsAnErrorNotAnEmptyList() async throws {
        defer { cleanUp() }
        try temp.file("vault/a.md", "alpha")
        try await write("vault")
        chmod(temp.path("disk/obsidian").path, 0)

        await #expect(throws: (any Error).self) {
            _ = try await destination.listSnapshots(sourceSlug: "obsidian")
        }
        await #expect(throws: (any Error).self) {
            try await destination.removeIncomplete(sourceSlug: "obsidian")
        }
    }

    // MARK: Disks under /Volumes

    @Test func leftoverFolderOfAnUnpluggedDiskIsUnavailable() async throws {
        defer { temp.remove() }
        try temp.directory("Volumes/HDD/Backups")
        let volumes = VolumeMounts(volumesRoot: temp.path("Volumes").path)
        for root in ["Volumes/HDD", "Volumes/HDD/Backups"] {
            let stale = LocalFolderDestination(root: temp.path(root), naming: Fixtures.naming, volumes: volumes)
            #expect(await stale.isAvailable() == false)
        }
        #expect(await LocalFolderDestination(root: temp.path("disk"), naming: Fixtures.naming, volumes: volumes).isAvailable())
    }

    @Test(arguments: ["", "/", "a/b", ".", "..", "../disk"])
    func folderNameThatIsNotOneFolderIsRefused(slug: String) async throws {
        defer { temp.remove() }
        let payload = try vaultPayload()
        try temp.file("disk/2026-09-27_100000/_snapshot.json", "{}")
        let snapshot = Snapshot(name: "2026-09-27_100000", date: Fixtures.date("2026-09-27 10:00:00"))
        let refused = DestinationError.invalidFolderName(slug)
        await #expect(throws: refused) { try await destination.listSnapshots(sourceSlug: slug) }
        await #expect(throws: refused) { try await destination.owners(sourceSlug: slug) }
        await #expect(throws: refused) { try await destination.removeIncomplete(sourceSlug: slug) }
        await #expect(throws: refused) { try await destination.delete(snapshot, sourceSlug: slug) }
        await #expect(throws: refused) { try await destination.materialize(snapshot, sourceSlug: slug, scratch: temp.path("scratch")) }
        await #expect(throws: refused) {
            try await destination.write(payload, manifest: manifest(), sourceSlug: slug, snapshotName: name, reusingStoredFiles: false)
        }
        #expect(temp.names(in: "disk") == ["2026-09-27_100000"])
        #expect(temp.names(in: "Trash").isEmpty)
    }

    @Test func leftoverFolderReachedAroundVolumesIsUnavailable() async throws {
        defer { temp.remove() }
        try temp.directory("Volumes/HDD/Backups")
        try FileManager.default.createSymbolicLink(at: temp.path("shortcut"), withDestinationURL: temp.path("Volumes/HDD/Backups"))
        let volumes = VolumeMounts(volumesRoot: temp.path("Volumes").path)
        let stale = LocalFolderDestination(root: temp.path("shortcut"), naming: Fixtures.naming, volumes: volumes)
        #expect(await stale.isAvailable() == false)
    }
}
