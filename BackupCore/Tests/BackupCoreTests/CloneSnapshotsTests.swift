import Darwin
import Foundation
import Testing
@testable import BackupCore

/// “Save space”: after a new copy is written in full and checked, its files that are the same as in the previous copy
/// of the source (same path, content and metadata) become clones of them.
struct CloneSnapshotsTests {
    private let temp: TempDirectory
    private let first = Fixtures.date("2026-09-01 10:00:00")
    private let second = Fixtures.date("2026-09-08 10:00:00")
    private let third = Fixtures.date("2026-09-15 10:00:00")
    private let sourceId = UUID()
    private let tags = "com.apple.metadata:_kMDItemUserTags"

    init() throws {
        temp = try TempDirectory()
        try temp.directory("disk")
    }

    private func destination(_ cloning: RecordingCloning) -> LocalFolderDestination {
        LocalFolderDestination(root: temp.path("disk"), naming: Fixtures.naming, cloning: cloning)
    }

    private func name(_ date: Date) -> String {
        Fixtures.naming.name(for: date)
    }

    private func backUp(_ destination: LocalFolderDestination, at date: Date, savesSpace: Bool = true) async throws {
        let payload = Payload(root: temp.path("vault"), collectedAt: date)
        let stats = PayloadWalker().stats(of: try PayloadWalker().entries(of: payload))
        let manifest = SnapshotManifest(
            sourceId: sourceId,
            sourceName: "Obsidian",
            collectedAt: date,
            fileCount: stats.fileCount,
            totalBytes: stats.totalBytes
        )
        try await destination.write(payload, manifest: manifest, sourceSlug: "obsidian", snapshotName: name(date), reusingStoredFiles: savesSpace)
    }

    private func snapshot(_ date: Date) -> URL {
        temp.path("disk/obsidian/\(name(date))")
    }

    private func content(_ date: Date, _ path: String) throws -> String {
        try String(contentsOf: snapshot(date).appendingPathComponent(path), encoding: .utf8)
    }

    private func manifest(_ date: Date) throws -> SnapshotManifest {
        try JSONCoding.decoder().decode(
            SnapshotManifest.self,
            from: Data(contentsOf: snapshot(date).appendingPathComponent(SnapshotManifest.fileName))
        )
    }

    private func treeContents(_ root: URL) throws -> [String: Data] {
        let payload = Payload(root: root, excludes: [SnapshotManifest.fileName], collectedAt: first)
        var result: [String: Data] = [:]
        for entry in try PayloadWalker().entries(of: payload) where entry.kind == .file {
            result[entry.relativePath] = try Data(contentsOf: entry.url)
        }
        return result
    }

    /// The file of the later copy shares all its data with the same file of the earlier one.
    private func isShared(_ path: String, between earlier: Date, and later: Date) -> Bool {
        guard let one = FileSpace(path: snapshot(earlier).appendingPathComponent(path).path)?.clone,
              let two = FileSpace(path: snapshot(later).appendingPathComponent(path).path)?.clone else { return false }
        return one.id == two.id && two.privateBytes == 0
    }

    private func leftovers(_ date: Date) -> [String] {
        (try? DirectoryNames.of(snapshot(date).path).filter { $0.hasPrefix(".backup-everything-clone-") }) ?? ["unreadable"]
    }

    @Test func unchangedFilesAreClonedAndEverySnapshotIsComplete() async throws {
        defer { temp.remove() }
        let cloning = RecordingCloning()
        try temp.file("vault/a.md", String(repeating: "alpha ", count: 4000))
        try temp.file("vault/notes/b.md", "beta")
        try await backUp(destination(cloning), at: first)

        try temp.file("vault/notes/b.md", "beta, edited")
        try temp.file("vault/c.md", "gamma")
        try await backUp(destination(cloning), at: second)

        #expect(cloning.clones.count == 1)
        #expect(isShared("a.md", between: first, and: second))
        #expect(!isShared("notes/b.md", between: first, and: second))
        #expect(try treeContents(snapshot(second)) == treeContents(temp.path("vault")))
        #expect(try content(first, "notes/b.md") == "beta")
        let files = try #require(try manifest(second).files)
        #expect(files.map(\.path) == ["a.md", "c.md", "notes/b.md"])
        #expect(try manifest(second).sharesData == true)
        #expect(leftovers(second).isEmpty)
    }

    @Test func foldersKeepTheirDatesWhenTheirFilesBecomeClones() async throws {
        defer { temp.remove() }
        try temp.file("vault/notes/a.md", "alpha")
        let dated = Fixtures.date("2026-08-01 12:00:00")
        try FileManager.default.setAttributes([.modificationDate: dated], ofItemAtPath: temp.path("vault/notes").path)
        try await backUp(destination(RecordingCloning()), at: first)
        try await backUp(destination(RecordingCloning()), at: second)

        #expect(isShared("notes/a.md", between: first, and: second))
        let attributes = try FileManager.default.attributesOfItem(atPath: snapshot(second).appendingPathComponent("notes").path)
        #expect(attributes[.modificationDate] as? Date == dated)
    }

    @Test func namesAreKeptByteForByte() async throws {
        defer { temp.remove() }
        let composed = "Куда пойти".precomposedStringWithCanonicalMapping
        let decomposed = "Мой план".decomposedStringWithCanonicalMapping
        let vault = try temp.directory("vault").path
        #expect(mkdir(vault + "/" + composed, 0o755) == 0)
        for name in ["\(composed)/\(composed).md", "\(decomposed).md"] {
            let descriptor = open(vault + "/" + name, O_CREAT | O_WRONLY, 0o644)
            #expect(descriptor >= 0)
            close(descriptor)
        }

        try await backUp(destination(RecordingCloning()), at: first)

        let stored = snapshot(first).path
        let names = try DirectoryNames.of(stored).filter { $0 != SnapshotManifest.fileName }
        #expect(Set(names.map { Array($0.utf8) }) == [Array(composed.utf8), Array("\(decomposed).md".utf8)])
        let inner = try DirectoryNames.of(stored + "/" + composed)
        #expect(inner.map { Array($0.utf8) } == [Array("\(composed).md".utf8)])
    }

    @Test func manifestHashesDescribeTheStoredFiles() async throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        try await backUp(destination(RecordingCloning()), at: first)

        let file = try #require(try manifest(first).files?.first)
        #expect(file.sha256 == "8ed3f6ad685b959ead7022518e1af76cd816f8e8ec7ccdda1ed4018e8f2223f8")
        #expect(file.size == 5)
    }

    @Test func movedFileIsCopiedInFull() async throws {
        defer { temp.remove() }
        let cloning = RecordingCloning()
        try temp.file("vault/photo.jpg", "pixels")
        try await backUp(destination(cloning), at: first)

        try FileManager.default.createDirectory(at: temp.path("vault/2026"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temp.path("vault/photo.jpg"), to: temp.path("vault/2026/IMG_1.jpg"))
        try await backUp(destination(cloning), at: second)

        #expect(cloning.clones.isEmpty)
        #expect(try content(second, "2026/IMG_1.jpg") == "pixels")
    }

    @Test func onlyThePreviousCopyIsShared() async throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/keep.md", "keep")
        try await backUp(destination(RecordingCloning()), at: first)
        let kept = temp.path("vault/a.md")
        try FileManager.default.moveItem(at: kept, to: temp.path("a.md"))
        try await backUp(destination(RecordingCloning()), at: second)
        try FileManager.default.moveItem(at: temp.path("a.md"), to: kept)

        try await backUp(destination(RecordingCloning()), at: third)

        #expect(!isShared("a.md", between: first, and: third))
        #expect(isShared("keep.md", between: second, and: third))
        #expect(try content(third, "a.md") == "alpha")
    }

    @Test func copyOfAnotherSourceIsNotShared() async throws {
        defer { temp.remove() }
        let cloning = RecordingCloning()
        try temp.file("vault/a.md", "alpha")
        try await backUp(destination(cloning), at: first)
        var stranger = try manifest(first)
        stranger.sourceId = UUID()
        try JSONCoding.encoder().encode(stranger).write(to: snapshot(first).appendingPathComponent(SnapshotManifest.fileName))

        try await backUp(destination(cloning), at: second)

        #expect(cloning.clones.isEmpty)
    }

    @Test func editingACloneLeavesTheOriginalIntact() async throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        try await backUp(destination(RecordingCloning()), at: first)
        try await backUp(destination(RecordingCloning()), at: second)
        #expect(isShared("a.md", between: first, and: second))

        try Data("broken".utf8).write(to: snapshot(second).appendingPathComponent("a.md"))

        #expect(try content(first, "a.md") == "alpha")
    }

    @Test func handEditedOldSnapshotIsNotUsedAsOriginal() async throws {
        defer { temp.remove() }
        let cloning = RecordingCloning()
        try temp.file("vault/a.md", "alpha")
        try await backUp(destination(cloning), at: first)

        try Data("ALPHA".utf8).write(to: snapshot(first).appendingPathComponent("a.md"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3600)],
            ofItemAtPath: snapshot(first).appendingPathComponent("a.md").path
        )
        try await backUp(destination(cloning), at: second)

        #expect(cloning.clones.isEmpty)
        #expect(try content(second, "a.md") == "alpha")
    }

    @Test func clonedFileKeepsTheOriginalsDates() async throws {
        defer { temp.remove() }
        let modified = Fixtures.date("2026-08-20 08:00:00")
        try temp.file("vault/a.md", "alpha", modified: modified)
        try await backUp(destination(RecordingCloning()), at: first)
        try await backUp(destination(RecordingCloning()), at: second)

        #expect(isShared("a.md", between: first, and: second))
        let attributes = try FileManager.default.attributesOfItem(atPath: snapshot(second).appendingPathComponent("a.md").path)
        #expect(attributes[.modificationDate] as? Date == modified)
    }

    @Test func incompleteSnapshotIsNotUsedAsOriginal() async throws {
        defer { temp.remove() }
        let cloning = RecordingCloning()
        try temp.file("vault/a.md", "alpha")
        try await backUp(destination(cloning), at: first)
        try FileManager.default.removeItem(at: snapshot(first).appendingPathComponent(SnapshotManifest.fileName))

        try await backUp(destination(cloning), at: second)

        #expect(cloning.clones.isEmpty)
    }

    @Test func snapshotsOfTheOldFormatAreNotUsedAsOriginals() async throws {
        defer { temp.remove() }
        let cloning = RecordingCloning()
        try temp.file("disk/obsidian/\(name(first))/a.md", "alpha")
        let old = SnapshotManifest(sourceId: sourceId, sourceName: "Obsidian", collectedAt: first, fileCount: 1, totalBytes: 5)
        try JSONCoding.encoder().encode(old).write(to: snapshot(first).appendingPathComponent(SnapshotManifest.fileName))
        try temp.file("vault/a.md", "alpha")

        try await backUp(destination(cloning), at: second)

        #expect(cloning.clones.isEmpty)
        #expect(try content(second, "a.md") == "alpha")
    }

    @Test func volumeWithoutClonesGetsFullCopies() async throws {
        defer { temp.remove() }
        let cloning = RecordingCloning(.unsupported)
        try temp.file("vault/a.md", "alpha")
        try await backUp(destination(cloning), at: first)
        try await backUp(destination(cloning), at: second)

        #expect(cloning.clones.isEmpty)
        #expect(try content(second, "a.md") == "alpha")
        #expect(try manifest(second).sharesData == false)
        #expect(try manifest(second).files?.count == 1)
    }

    @Test func sourceThatDoesNotSaveSpaceGetsFullCopies() async throws {
        defer { temp.remove() }
        let cloning = RecordingCloning()
        try temp.file("vault/a.md", "alpha")
        try await backUp(destination(cloning), at: first, savesSpace: false)
        try await backUp(destination(cloning), at: second, savesSpace: false)

        #expect(cloning.clones.isEmpty)
        #expect(try manifest(second).sharesData == false)
        #expect(try content(second, "a.md") == "alpha")
    }

    @Test func destinationTellsWhetherCopiesCanShareFiles() async throws {
        defer { temp.remove() }
        #expect(await destination(RecordingCloning()).canShareUnchangedFiles() == true)
        #expect(await destination(RecordingCloning(.unsupported)).canShareUnchangedFiles() == false)
        let unplugged = LocalFolderDestination(root: temp.path("Volumes/HDD"), naming: Fixtures.naming, cloning: RecordingCloning())
        #expect(await unplugged.canShareUnchangedFiles() == nil)
    }

    @Test func failedCloneKeepsTheFullFile() async throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        try await backUp(destination(RecordingCloning()), at: first)
        try await backUp(destination(RecordingCloning(.failing)), at: second)

        #expect(!isShared("a.md", between: first, and: second))
        #expect(try content(second, "a.md") == "alpha")
        #expect(try manifest(second).files?.first?.sha256 == manifest(first).files?.first?.sha256)
        #expect(leftovers(second).isEmpty)
    }

    @Test func cloneOfAnotherSizeKeepsTheFullFile() async throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        try await backUp(destination(RecordingCloning()), at: first)

        try await backUp(destination(RecordingCloning(.truncating)), at: second)

        #expect(try content(second, "a.md") == "alpha")
        #expect(try manifest(second).files?.first?.size == 5)
        #expect(leftovers(second).isEmpty)
    }

    @Test func deletingTheOldSnapshotKeepsTheNewOneWhole() async throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/b.md", "beta")
        let destination = destination(RecordingCloning())
        try await backUp(destination, at: first)
        try temp.file("vault/b.md", "beta, edited")
        try await backUp(destination, at: second)

        try await destination.delete(Snapshot(name: name(first), date: first), sourceSlug: "obsidian")

        #expect(!FileManager.default.fileExists(atPath: snapshot(first).path))
        #expect(try treeContents(snapshot(second)) == treeContents(temp.path("vault")))
    }

    @Test func usedBytesCountsSharedContentOnce() async throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "12345")
        try temp.file("vault/b.md", "123")
        let destination = destination(RecordingCloning())
        try await backUp(destination, at: first)
        try temp.file("vault/b.md", "1234567")
        try await backUp(destination, at: second)
        try temp.file("disk/notes.txt", "12")

        let (one, two) = ("disk/obsidian/\(name(first))", "disk/obsidian/\(name(second))")
        let expected = try temp.allocatedBytes(
            "\(one)/a.md", "\(one)/b.md", "\(two)/b.md", "disk/notes.txt",
            "\(one)/\(SnapshotManifest.fileName)", "\(two)/\(SnapshotManifest.fileName)"
        )
        #expect(try await destination.usedBytes() == expected)
    }

    @Test func usedBytesCountsFullCopiesInFull() async throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "12345")
        let destination = destination(RecordingCloning(.unsupported))
        try await backUp(destination, at: first)
        try await backUp(destination, at: second)

        let (one, two) = ("disk/obsidian/\(name(first))", "disk/obsidian/\(name(second))")
        let expected = try temp.allocatedBytes(
            "\(one)/a.md", "\(two)/a.md",
            "\(one)/\(SnapshotManifest.fileName)", "\(two)/\(SnapshotManifest.fileName)"
        )
        #expect(try await destination.usedBytes() == expected)
    }

    @Test func usedBytesDoesNotNeedManifests() async throws {
        defer { temp.remove() }
        try temp.file("vault/photo.jpg", String(repeating: "x", count: 100_000))
        let destination = destination(RecordingCloning())
        for date in [first, second, third] {
            try await backUp(destination, at: date)
        }
        for date in [first, second, third] {
            try FileManager.default.moveItem(
                at: snapshot(date).appendingPathComponent(SnapshotManifest.fileName),
                to: temp.path("\(name(date)).json")
            )
        }

        #expect(try await destination.usedBytes() == temp.allocatedBytes("disk/obsidian/\(name(first))/photo.jpg"))
    }

    // MARK: Only files with the same metadata are shared

    @Test func fileWhoseMetadataChangedIsNotShared() async throws {
        defer { Permissions.removeTree(temp.url) }
        let tagged = try temp.file("vault/tagged.jpg", "pixels")
        let opened = try temp.file("vault/opened.jpg", "scan")
        let hidden = try temp.file("vault/hidden.jpg", "hidden")
        try temp.file("vault/same.jpg", "same")
        try Permissions.setAttribute(tags, value: "Red", on: tagged)
        try await backUp(destination(RecordingCloning()), at: first)

        try Permissions.setAttribute(tags, value: "Green", on: tagged)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: opened.path)
        #expect(chflags(hidden.path, UInt32(UF_HIDDEN)) == 0)
        try await backUp(destination(RecordingCloning()), at: second)

        #expect(isShared("same.jpg", between: first, and: second))
        for path in ["tagged.jpg", "opened.jpg", "hidden.jpg"] {
            #expect(!isShared(path, between: first, and: second), "\(path)")
        }
        let stored = snapshot(second)
        #expect(try Permissions.attribute(tags, of: stored.appendingPathComponent("tagged.jpg")) == "Green")
        let permissions = try FileManager.default.attributesOfItem(atPath: stored.appendingPathComponent("opened.jpg").path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func fileWithTheSameTagsIsShared() async throws {
        defer { temp.remove() }
        let file = try temp.file("vault/a.md", "alpha")
        try Permissions.setAttribute(tags, value: "Red", on: file)
        try await backUp(destination(RecordingCloning()), at: first)
        try await backUp(destination(RecordingCloning()), at: second)

        #expect(isShared("a.md", between: first, and: second))
        #expect(try Permissions.attribute(tags, of: snapshot(second).appendingPathComponent("a.md")) == "Red")
    }

    /// Replacing a file needs the right to delete it: a file whose access list forbids that keeps its full copy.
    @Test func fileThatMayNotBeDeletedKeepsItsFullCopy() async throws {
        defer { Permissions.removeTree(temp.url) }
        try Permissions.denyDeleting(try temp.file("vault/a.md", "alpha"))
        try await backUp(destination(RecordingCloning()), at: first)
        try await backUp(destination(RecordingCloning()), at: second)

        #expect(!isShared("a.md", between: first, and: second))
        #expect(try content(second, "a.md") == "alpha")
        #expect(Permissions.accessList(of: snapshot(second).appendingPathComponent("a.md"))?.contains("deny") == true)
        #expect(leftovers(second).isEmpty)
    }

    @Test func lockedFileIsCopiedInFullAndStaysLocked() async throws {
        defer { Permissions.removeTree(temp.url) }
        try temp.file("vault/a.md", "alpha")
        try Permissions.lock(try temp.file("vault/contract.pdf", "signed"))
        try await backUp(destination(RecordingCloning()), at: first)

        try await backUp(destination(RecordingCloning()), at: second)

        #expect(isShared("a.md", between: first, and: second))
        #expect(!isShared("contract.pdf", between: first, and: second))
        #expect(try content(second, "contract.pdf") == "signed")
        let flags = try FileManager.default.attributesOfItem(atPath: snapshot(second).appendingPathComponent("contract.pdf").path)[.immutable] as? Bool
        #expect(flags == true)
    }

    // MARK: Files kept compressed by APFS

    @discardableResult
    private func compressedVault() throws -> URL {
        let file = try temp.directory("vault").appendingPathComponent("notes.txt")
        try Compression.write(Compression.sample, compressedAt: file)
        return file
    }

    @Test func compressedFileStaysWholeInEveryCopy() async throws {
        defer { temp.remove() }
        let cloning = RecordingCloning()
        try compressedVault()

        for date in [first, second, third] {
            try await backUp(destination(cloning), at: date)
        }

        #expect(cloning.clones.count == 2)
        for date in [first, second, third] {
            #expect(try content(date, "notes.txt") == Compression.sample)
            #expect(try manifest(date).files?.first?.size == Int64(Compression.sample.utf8.count))
            #expect(Compression.isCompressed(snapshot(date).appendingPathComponent("notes.txt")))
        }
    }

    @Test func plainFileIsNotSharedWithACompressedOne() async throws {
        defer { temp.remove() }
        let cloning = RecordingCloning()
        let file = try compressedVault()
        try await backUp(destination(cloning), at: first)

        try FileManager.default.removeItem(at: file)
        try temp.file("vault/notes.txt", Compression.sample)
        try await backUp(destination(cloning), at: second)

        #expect(cloning.clones.isEmpty)
        #expect(try content(second, "notes.txt") == Compression.sample)
        #expect(!Compression.isCompressed(snapshot(second).appendingPathComponent("notes.txt")))
    }

    @Test func compressedFileCaughtUpToAnotherDiskStaysWhole() async throws {
        defer { temp.remove() }
        try compressedVault()
        try await backUp(destination(RecordingCloning()), at: first)
        try await backUp(destination(RecordingCloning()), at: second)
        let other = LocalFolderDestination(root: try temp.directory("other"), naming: Fixtures.naming, cloning: RecordingCloning())

        for date in [first, second] {
            let payload = Payload(root: snapshot(date), excludedAtTop: SnapshotManifest.serviceFileNames, collectedAt: date)
            let manifest = SnapshotManifest(sourceId: sourceId, sourceName: "Obsidian", collectedAt: date, fileCount: 1, totalBytes: 1)
            try await other.write(payload, manifest: manifest, sourceSlug: "obsidian", snapshotName: name(date), reusingStoredFiles: true)
        }

        for date in [first, second] {
            let copied = temp.path("other/obsidian/\(name(date))/notes.txt")
            #expect(try String(contentsOf: copied, encoding: .utf8) == Compression.sample)
            #expect(Compression.isCompressed(copied))
        }
        #expect(!FileManager.default.fileExists(atPath: temp.path("other/obsidian/\(name(first))/\(SnapshotManifest.unfinishedMarker)").path))
    }

    /// An earlier version emptied compressed clones and wrote size 0 with the hash of the source into the manifest.
    @Test func storedFileOfAnotherSizeThanTheSourceIsNotUsedAsOriginal() async throws {
        defer { temp.remove() }
        let cloning = RecordingCloning()
        try temp.file("vault/a.md", "alpha")
        try await backUp(destination(cloning), at: first)
        let stored = snapshot(first).appendingPathComponent("a.md")
        let modified = try FileManager.default.attributesOfItem(atPath: stored.path)[.modificationDate] as? Date
        try Data().write(to: stored)
        try FileManager.default.setAttributes([.modificationDate: modified as Any], ofItemAtPath: stored.path)
        var broken = try manifest(first)
        broken.files = broken.files?.map { SnapshotFile(path: $0.path, size: 0, sha256: $0.sha256, modified: $0.modified) }
        try JSONCoding.encoder().encode(broken).write(to: snapshot(first).appendingPathComponent(SnapshotManifest.fileName))

        try await backUp(destination(cloning), at: second)

        #expect(cloning.clones.isEmpty)
        #expect(try content(second, "a.md") == "alpha")
    }
}
