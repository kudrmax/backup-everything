import Darwin
import Foundation
import Testing
@testable import BackupCore

/// Disks formatted for Windows and cameras (exFAT, FAT32) have no access lists and only some of the flags: copies go
/// there without them, and are written, cloned, caught up and deleted like anywhere else.
struct ForeignFileSystemTests {
    private let temp: TempDirectory
    private let first = Fixtures.date("2026-09-01 10:00:00")
    private let second = Fixtures.date("2026-09-08 10:00:00")
    private let tags = "com.apple.metadata:_kMDItemUserTags"

    init() throws {
        temp = try TempDirectory()
    }

    private func name(_ date: Date) -> String {
        Fixtures.naming.name(for: date)
    }

    /// What a person's folder carries: subfolders, a read-only folder, a locked file, tags, access lists, hidden and nodump flags.
    private func vault() throws -> Payload {
        try temp.file("vault/a.md", "alpha")
        let note = try temp.file("vault/notes/b.md", "beta")
        try temp.file("vault/readonly/c.md", "gamma")
        try Permissions.setAttribute(tags, value: "Red", on: note)
        try Permissions.setAttribute(tags, value: "Blue", on: temp.path("vault/notes"))
        try Permissions.denyDeleting(note)
        try Permissions.denyDeleting(temp.path("vault/notes"))
        #expect(chflags(note.path, UInt32(UF_HIDDEN | UF_NODUMP)) == 0)
        #expect(chflags(temp.path("vault/notes").path, UInt32(UF_NODUMP)) == 0)
        try Permissions.lock(temp.path("vault/a.md"))
        #expect(chmod(temp.path("vault/readonly").path, 0o555) == 0)
        return Payload(root: temp.path("vault"), collectedAt: first)
    }

    private func manifest(_ date: Date) -> SnapshotManifest {
        SnapshotManifest(sourceId: UUID(), sourceName: "Obsidian", collectedAt: date, fileCount: 3, totalBytes: 14)
    }

    private func flags(_ url: URL) -> UInt32 {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_flags : 0
    }

    @Test(arguments: [DiskImage.Format.exFAT, .fat32])
    func copiesAreWrittenAndDeleted(_ format: DiskImage.Format) async throws {
        defer { Permissions.removeTree(temp.url) }
        let disk = try DiskImage(format)
        let destination = LocalFolderDestination(root: disk.root, naming: Fixtures.naming)
        let payload = try vault()

        try await destination.write(payload, manifest: manifest(first), sourceSlug: "obsidian", snapshotName: name(first), reusingStoredFiles: true)
        try await destination.write(payload, manifest: manifest(second), sourceSlug: "obsidian", snapshotName: name(second), reusingStoredFiles: true)

        let stored = disk.root.appendingPathComponent("obsidian/\(name(second))")
        #expect(try String(contentsOf: stored.appendingPathComponent("notes/b.md"), encoding: .utf8) == "beta")
        #expect(try Permissions.attribute(tags, of: stored.appendingPathComponent("notes/b.md")) == "Red")
        #expect(try Permissions.attribute(tags, of: stored.appendingPathComponent("notes")) == "Blue")
        #expect(flags(stored.appendingPathComponent("notes/b.md")) & UInt32(UF_HIDDEN) != 0)
        #expect(flags(stored.appendingPathComponent("a.md")) & UInt32(UF_IMMUTABLE) != 0)
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").map(\.name) == [name(first), name(second)])

        try await destination.delete(Snapshot(name: name(first), date: first), sourceSlug: "obsidian")
        try await destination.delete(Snapshot(name: name(second), date: second), sourceSlug: "obsidian")
        #expect(try FileManager.default.contentsOfDirectory(atPath: disk.root.appendingPathComponent("obsidian").path).isEmpty)
    }

    @Test(arguments: [DiskImage.Format.exFAT, .fat32])
    func copyIsCaughtUpBetweenDisks(_ format: DiskImage.Format) async throws {
        defer { Permissions.removeTree(temp.url) }
        let disk = try DiskImage(format)
        let apfs = LocalFolderDestination(root: try temp.directory("ssd"), naming: Fixtures.naming)
        let foreign = LocalFolderDestination(root: disk.root, naming: Fixtures.naming)
        try await apfs.write(try vault(), manifest: manifest(first), sourceSlug: "obsidian", snapshotName: name(first), reusingStoredFiles: true)

        let snapshot = Snapshot(name: name(first), date: first)
        let fromApfs = Payload(root: try await apfs.materialize(snapshot, sourceSlug: "obsidian", scratch: temp.url), excludedAtTop: SnapshotManifest.serviceFileNames, collectedAt: first)
        try await foreign.write(fromApfs, manifest: manifest(first), sourceSlug: "obsidian", snapshotName: name(first), reusingStoredFiles: true)

        try await apfs.delete(snapshot, sourceSlug: "obsidian")
        let fromForeign = Payload(root: try await foreign.materialize(snapshot, sourceSlug: "obsidian", scratch: temp.url), excludedAtTop: SnapshotManifest.serviceFileNames, collectedAt: first)
        try await apfs.write(fromForeign, manifest: manifest(first), sourceSlug: "obsidian", snapshotName: name(first), reusingStoredFiles: true)

        let back = temp.path("ssd/obsidian/\(name(first))")
        #expect(try String(contentsOf: back.appendingPathComponent("readonly/c.md"), encoding: .utf8) == "gamma")
        #expect(try Permissions.attribute(tags, of: back.appendingPathComponent("notes/b.md")) == "Red")
    }

    @Test(arguments: [DiskImage.Format.exFAT, .fat32])
    func workFoldersWithAccessListsAreRemoved(_ format: DiskImage.Format) throws {
        let disk = try DiskImage(format)
        let staging = disk.root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let file = staging.appendingPathComponent("sub/a.md")
        try Data("alpha".utf8).write(to: file)
        try Permissions.lock(file)
        #expect(chmod(staging.appendingPathComponent("sub").path, 0o555) == 0)

        try FolderRemoval().remove(staging.path)

        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    // MARK: Metadata on a target that is read-only

    @Test func readOnlyTargetTakesExtendedAttributes() throws {
        defer { temp.remove() }
        let source = try temp.file("source.md", "hello")
        let target = try temp.file("target.md", "hello")
        try Permissions.setAttribute(tags, value: "Red", on: source)
        try Permissions.setAttribute("user.old", value: "x", on: target)
        #expect(chmod(source.path, 0o444) == 0)
        #expect(chmod(target.path, 0o444) == 0)

        try FileMetadata().apply(from: source.path, to: target.path)

        #expect(try Permissions.attribute(tags, of: target) == "Red")
        #expect(throws: (any Error).self) { try Permissions.attribute("user.old", of: target) }
        #expect(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber == 0o444)
    }

    @Test func accessListOfTheTargetGoesWhenTheSourceHasNone() throws {
        let target = try temp.file("target.md")
        defer {
            try? Permissions.dropAccessList(target)
            temp.remove()
        }
        try Permissions.denyDeleting(target)

        try FileMetadata().apply(from: try temp.file("source.md").path, to: target.path)

        #expect(Permissions.accessList(of: target) == nil)
    }

    @Test func readOnlyFileWithTagsIsCloned() throws {
        defer { temp.remove() }
        let file = try temp.file("vault/doc.txt", String(repeating: "z", count: 100_000))
        try Permissions.setAttribute(tags, value: "Red", on: file)
        #expect(chmod(file.path, 0o444) == 0)
        let cloning = RecordingCloning()
        let writer = SnapshotWriter(cloning: cloning)
        let listing = try PayloadWalker().listing(of: Payload(root: temp.path("vault"), collectedAt: first))
        let earlier = try temp.directory("disk/first")
        let stored = try writer.write(listing, into: earlier, reusing: .empty)

        let contents = try writer.write(
            listing,
            into: try temp.directory("disk/second"),
            reusing: StoredContentIndex(snapshots: [(earlier, manifest(first).with(files: stored.files))])
        )

        #expect(contents.cloneFailures.isEmpty)
        #expect(cloning.clonedTargets(relativeTo: temp.path("disk/second")) == ["doc.txt"])
        #expect(try Permissions.attribute(tags, of: temp.path("disk/second/doc.txt")) == "Red")
    }

    @Test func failedCloneIsCopiedAndReported() throws {
        defer { temp.remove() }
        try temp.file("vault/doc.txt", "data")
        let listing = try PayloadWalker().listing(of: Payload(root: temp.path("vault"), collectedAt: first))
        let earlier = try temp.directory("disk/first")
        let stored = try SnapshotWriter(cloning: APFSCloning()).write(listing, into: earlier, reusing: .empty)

        let contents = try SnapshotWriter(cloning: RecordingCloning(.failing)).write(
            listing,
            into: try temp.directory("disk/second"),
            reusing: StoredContentIndex(snapshots: [(earlier, manifest(first).with(files: stored.files))])
        )

        #expect(contents.cloneFailures.keys.sorted() == ["doc.txt"])
        #expect(try String(contentsOf: temp.path("disk/second/doc.txt"), encoding: .utf8) == "data")
    }
}

private extension SnapshotManifest {
    func with(files: [SnapshotFile]) -> SnapshotManifest {
        var manifest = self
        manifest.files = files
        return manifest
    }
}
