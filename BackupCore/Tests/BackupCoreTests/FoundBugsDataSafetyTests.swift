import Darwin
import Foundation
import Testing
@testable import BackupCore

/// Reproductions of data-safety bugs found in review. Every test here fails until its bug is fixed.
@Suite(.serialized)
struct FoundBugsDataSafetyTests {
    private let temp: TempDirectory
    private let first = Fixtures.date("2026-09-01 10:00:00")
    private let second = Fixtures.date("2026-09-08 10:00:00")

    init() throws {
        temp = try TempDirectory()
        try temp.directory("disk")
        try temp.directory("Trash")
    }

    private func cleanUp() {
        Permissions.unlockTree(temp.url)
        temp.remove()
    }

    private func destination(_ folder: String = "disk", cloning: any FileCloning = APFSCloning()) -> LocalFolderDestination {
        let trashFolder = temp.path("Trash")
        return LocalFolderDestination(root: temp.path(folder), naming: Fixtures.naming, cloning: cloning) { url in
            try FileManager.default.moveItem(at: url, to: trashFolder.appendingPathComponent(UUID().uuidString))
        }
    }

    private func manifest(_ date: Date, sourceId: UUID = UUID(), payload: Payload) throws -> SnapshotManifest {
        let stats = PayloadWalker().stats(of: try PayloadWalker().entries(of: payload))
        return SnapshotManifest(sourceId: sourceId, sourceName: "Obsidian", collectedAt: date, fileCount: stats.fileCount, totalBytes: stats.totalBytes)
    }

    private func backUp(
        _ root: URL,
        to destination: LocalFolderDestination,
        at date: Date,
        slug: String = "obsidian",
        sourceId: UUID = UUID(),
        savesSpace: Bool = true
    ) async throws {
        let payload = Payload(root: root, collectedAt: date)
        try await destination.write(
            payload,
            manifest: try manifest(date, sourceId: sourceId, payload: payload),
            sourceSlug: slug,
            snapshotName: Fixtures.naming.name(for: date),
            reusingStoredFiles: savesSpace
        )
    }

    private func snapshotPath(_ date: Date, slug: String = "obsidian", in folder: String = "disk") -> String {
        "\(folder)/\(slug)/\(Fixtures.naming.name(for: date))"
    }

    // MARK: Locked files (Finder “Locked”, `chflags uchg`)

    @Test func lockedFileInTheSourceMakesEveryBackupAfterTheFirstFail() async throws {
        defer { cleanUp() }
        try temp.file("vault/a.md", "alpha")
        let locked = try temp.file("vault/contract.pdf", "signed")
        try Permissions.lock(locked)

        try await backUp(temp.path("vault"), to: destination(), at: first)
        await #expect(throws: Never.self, "the second copy clones the locked file, cannot set its dates, cannot remove the clone and then cannot copy over it") {
            try await backUp(temp.path("vault"), to: destination(), at: second)
        }
    }

    @Test func retentionCannotDeleteACopyWithALockedFileAndLeavesItHalfDeleted() async throws {
        defer { cleanUp() }
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/m.md", "middle")
        try temp.file("vault/z.md", "omega")
        try Permissions.lock(temp.path("vault/m.md"))
        try await backUp(temp.path("vault"), to: destination(), at: first, savesSpace: false)
        let snapshot = Snapshot(name: Fixtures.naming.name(for: first), date: first)

        await #expect(throws: Never.self) {
            try await destination().delete(snapshot, sourceSlug: "obsidian")
        }
        let left = temp.names(in: snapshotPath(first))
        #expect(left.isEmpty, "copy is half deleted and stays forever: \(left)")
    }

    // MARK: Source contents silently missing from a “successful” copy

    @Test func unreadableSubfolderIsSilentlyLeftOutOfTheCopy() async throws {
        defer { cleanUp() }
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/private/diary.md", "secret")
        chmod(temp.path("vault/private").path, 0)

        await #expect(throws: (any Error).self, "a copy without the folder contents must not count as a backup") {
            try await backUp(temp.path("vault"), to: destination(), at: first)
        }
        chmod(temp.path("vault/private").path, 0o755)
        #expect(try await destination().listSnapshots(sourceSlug: "obsidian").isEmpty)
    }

    @Test func singleFileSourceThatIsASymlinkIsStoredAsALinkWithoutData() async throws {
        defer { cleanUp() }
        let real = try temp.file("dotfiles/zshrc", "export PATH=/opt/homebrew/bin")
        try temp.directory("home")
        try FileManager.default.createSymbolicLink(at: temp.path("home/.zshrc"), withDestinationURL: real)

        try await backUp(temp.path("home/.zshrc"), to: destination(), at: first)

        let stored = temp.path(snapshotPath(first) + "/.zshrc")
        let type = try FileManager.default.attributesOfItem(atPath: stored.path)[.type] as? FileAttributeType
        #expect(type == .typeRegular, "the copy holds only a link to the original, no data")
    }

    // MARK: Folder metadata

    @Test func folderPermissionsAreNotKeptInTheCopy() async throws {
        defer { cleanUp() }
        try temp.file("vault/keys/id_ed25519", "PRIVATE")
        chmod(temp.path("vault/keys").path, 0o700)

        try await backUp(temp.path("vault"), to: destination(), at: first)

        let attributes = try FileManager.default.attributesOfItem(atPath: temp.path(snapshotPath(first) + "/keys").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func clonedFileKeepsExtendedAttributesOfTheOldCopy() async throws {
        defer { cleanUp() }
        let file = try temp.file("vault/photo.jpg", "pixels")
        try Permissions.setAttribute("com.apple.metadata:_kMDItemUserTags", value: "Red", on: file)
        try await backUp(temp.path("vault"), to: destination(), at: first)

        try Permissions.setAttribute("com.apple.metadata:_kMDItemUserTags", value: "Green", on: file)
        try await backUp(temp.path("vault"), to: destination(), at: second)

        let stored = temp.path(snapshotPath(second) + "/photo.jpg")
        #expect(try Permissions.attribute("com.apple.metadata:_kMDItemUserTags", of: stored) == "Green")
    }

    // MARK: App file names inside the person's data

    @Test func halfWrittenCopyOfAFolderWithItsOwnSnapshotJsonCountsAsFinished() async throws {
        defer { cleanUp() }
        try temp.file("vault/_snapshot.json", "{\"note\": \"exported by another tool\"}")
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/zz.md", "unreadable")
        chmod(temp.path("vault/zz.md").path, 0)

        await #expect(throws: (any Error).self) {
            try await backUp(temp.path("vault"), to: destination(), at: first)
        }
        chmod(temp.path("vault/zz.md").path, 0o644)

        #expect(try await destination().listSnapshots(sourceSlug: "obsidian").isEmpty, "a half-written copy is listed as a finished one")
        try await destination().removeIncomplete(sourceSlug: "obsidian")
        #expect(!temp.exists(snapshotPath(first)), "the half-written copy is never cleaned up")
    }

    @Test func catchUpCopyDropsFilesNamedLikeAppServiceFiles() async throws {
        defer { cleanUp() }
        try temp.directory("cloud")
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/projects/site/_snapshot.json", "{\"page\": 1}")
        try temp.file("vault/projects/draft/_unfinished", "todo list")
        let source = Fixtures.source()
        try await backUp(temp.path("vault"), to: destination(), at: first, slug: source.slug)

        let disk = Fixtures.localDestination("HDD", at: temp.path("disk"))
        let cloud = Fixtures.localDestination("Backup folder", at: temp.path("cloud"))
        let stores = LocalStores(trash: temp.path("Trash"))
        let engine = BackupEngine(
            providers: stores,
            stores: stores,
            retention: RetentionPolicy(timeZone: Fixtures.utc),
            naming: Fixtures.naming,
            time: FakeTimeSource(second)
        )
        let record = await engine.copy(Snapshot(name: Fixtures.naming.name(for: first), date: first), of: source, from: disk, to: [cloud])
        #expect(record.deliveries.map(\.outcome.isDelivered) == [true])

        let copied = snapshotPath(first, slug: source.slug, in: "cloud")
        #expect(temp.exists(copied + "/projects/site/_snapshot.json"))
        #expect(temp.exists(copied + "/projects/draft/_unfinished"))
    }

    // MARK: Copies of another source

    @Test func newSourceWithTheNameOfARemovedOnePrunesTheOldSourcesCopies() async throws {
        defer { cleanUp() }
        let editor = ConfigEditor()
        var config = Config()
        let removed = editor.makeSource(name: "Photos", steps: [.folder("/tmp/none")], now: first, in: config)
        editor.save(removed, in: &config)
        try temp.file("vault/a.jpg", "old photo")
        let oldDays = ["2026-09-01 10:00:00", "2026-09-02 10:00:00", "2026-09-03 10:00:00"].map(Fixtures.date)
        for day in oldDays {
            try await backUp(temp.path("vault"), to: destination(), at: day, slug: removed.slug, sourceId: removed.id)
        }
        editor.removeSource(removed.id, from: &config)

        let disk = Fixtures.localDestination("HDD", at: temp.path("disk"))
        var fresh = editor.makeSource(name: "Photos", steps: [.folder("/tmp/none")], now: second, in: config)
        fresh.retention = RetentionRules(daily: 1, weekly: 0, monthly: 0, yearly: 0)
        fresh.destinationIds = [disk.id]
        #expect(fresh.slug == removed.slug)

        try temp.file("new/b.jpg", "new photo")
        let provider = FakeSourceProvider(result: .success(Payload(root: temp.path("new"), collectedAt: second)))
        let stores = LocalStores(trash: temp.path("Trash"), provider: provider)
        let engine = BackupEngine(
            providers: stores,
            stores: stores,
            retention: RetentionPolicy(timeZone: Fixtures.utc),
            naming: Fixtures.naming,
            time: FakeTimeSource(second)
        )
        _ = await engine.run(source: fresh, destinations: [disk], trigger: .scheduled)

        for day in oldDays {
            #expect(temp.exists(snapshotPath(day, slug: removed.slug)), "copy of the removed source was deleted by the new source's rules")
        }
    }

    // MARK: Names without a time zone

    @Test func copyNamesAreAmbiguousWhenClocksGoBackSoTheFresherCopyOfTheDayIsDeleted() throws {
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let naming = SnapshotNaming(timeZone: berlin)
        let earlier = Fixtures.date("2026-10-25 00:50:00")
        let later = Fixtures.date("2026-10-25 01:10:00")
        let nextDay = Fixtures.date("2026-10-26 09:00:00")
        let listed = [earlier, later, nextDay].map { naming.snapshot(named: naming.name(for: $0))! }

        #expect(listed[0].date == earlier, "02:50 before clocks went back is read as 02:50 after, later than 02:10 after")
        let doomed = RetentionPolicy(timeZone: berlin)
            .snapshotsToDelete(listed, rules: RetentionRules(daily: 2, weekly: 0, monthly: 0, yearly: 0))
        #expect(doomed.map(\.name) == [naming.name(for: earlier)], "the latest copy of 25 October must stay")
    }

    // MARK: Cloud

    @Test func cloudCopyIsWrittenIntoAFolderInTheWayInsteadOfRefusing() async throws {
        defer { cleanUp() }
        let date = Fixtures.date("2026-09-28 14:30:00")
        let name = Fixtures.naming.name(for: date)
        let file = try temp.file("export.csv", "1;2")
        let runner = FakeProcessRunner { call in
            if call.arguments.first == "lsf", call.arguments.contains(where: { $0.hasSuffix("/finance/\(name)") || $0.hasSuffix("/finance") }) {
                return ProcessResult(exitCode: 0, stdout: "\(name)/\nold-export.csv\n")
            }
            return ProcessResult(exitCode: 0)
        }
        let cloud = RcloneDestination(
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/rclone"),
            remote: "gdrive",
            path: "backups",
            runner: runner,
            naming: Fixtures.naming
        )
        let payload = Payload(root: file, collectedAt: date)

        await #expect(throws: DestinationError.self, "spec 4.3: a folder without the mark under the copy name is in the way, nothing is written") {
            try await cloud.write(payload, manifest: try manifest(date, payload: payload), sourceSlug: "finance", snapshotName: name, reusingStoredFiles: false)
        }
    }

    // MARK: Listing errors

    @Test func unreadableSourceFolderLooksLikeAllCopiesAreGone() async throws {
        defer { cleanUp() }
        try temp.file("vault/a.md", "alpha")
        try await backUp(temp.path("vault"), to: destination(), at: first)
        chmod(temp.path("disk/obsidian").path, 0)
        defer { chmod(temp.path("disk/obsidian").path, 0o755) }

        await #expect(throws: (any Error).self, "spec 5.3.1: a list that could not be read is not a missing copy") {
            _ = try await destination().listSnapshots(sourceSlug: "obsidian")
        }
    }
}

private struct LocalStores: SourceProviderFactory, DestinationStoreFactory {
    let trash: URL
    var provider = FakeSourceProvider(result: .failure(SourceError.emptyResult))

    func provider(for source: Source) -> any SourceProvider { provider }

    func store(for destination: Destination) -> any DestinationStore {
        guard case let .localFolder(path) = destination.kind else { fatalError("local folders only") }
        let trash = self.trash
        return LocalFolderDestination(root: URL(fileURLWithPath: path), naming: Fixtures.naming) { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
        }
    }
}

private enum Permissions {
    static func lock(_ url: URL) throws {
        guard chflags(url.path, UInt32(UF_IMMUTABLE)) == 0 else { throw POSIXError(.EPERM) }
    }

    static func unlockTree(_ root: URL) {
        chflags(root.path, 0)
        chmod(root.path, 0o755)
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return }
        while let relative = enumerator.nextObject() as? String {
            let path = root.path + "/" + relative
            lchflags(path, 0)
            if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                chmod(path, 0o755)
            }
        }
    }

    static func setAttribute(_ name: String, value: String, on url: URL) throws {
        let data = Array(value.utf8)
        guard setxattr(url.path, name, data, data.count, 0, XATTR_NOFOLLOW) == 0 else { throw POSIXError(.EIO) }
    }

    static func attribute(_ name: String, of url: URL) throws -> String {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = getxattr(url.path, name, &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        guard length >= 0 else { throw POSIXError(.ENOATTR) }
        return String(decoding: buffer.prefix(length), as: UTF8.self)
    }
}
