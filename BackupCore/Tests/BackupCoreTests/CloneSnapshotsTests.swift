import Foundation
import Testing
@testable import BackupCore

struct CloneSnapshotsTests {
    private let temp: TempDirectory
    private let first = Fixtures.date("2026-09-01 10:00:00")
    private let second = Fixtures.date("2026-09-08 10:00:00")
    private let third = Fixtures.date("2026-09-15 10:00:00")

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

    private func backUp(_ destination: LocalFolderDestination, at date: Date) async throws {
        let payload = Payload(root: temp.path("vault"), collectedAt: date)
        let stats = PayloadWalker().stats(of: try PayloadWalker().entries(of: payload))
        let manifest = SnapshotManifest(
            sourceId: UUID(),
            sourceName: "Obsidian",
            collectedAt: date,
            fileCount: stats.fileCount,
            totalBytes: stats.totalBytes
        )
        try await destination.write(payload, manifest: manifest, sourceSlug: "obsidian", snapshotName: name(date))
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

    @Test func unchangedFilesAreClonedAndEverySnapshotIsComplete() async throws {
        defer { temp.remove() }
        let cloning = RecordingCloning()
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/notes/b.md", "beta")
        try await backUp(destination(cloning), at: first)

        try temp.file("vault/notes/b.md", "beta, edited")
        try temp.file("vault/c.md", "gamma")
        try await backUp(destination(cloning), at: second)

        #expect(cloning.clonedTargets(relativeTo: snapshot(second)) == ["a.md"])
        #expect(try treeContents(snapshot(second)) == treeContents(temp.path("vault")))
        #expect(try content(first, "notes/b.md") == "beta")
        let files = try #require(try manifest(second).files)
        #expect(files.map(\.path) == ["a.md", "c.md", "notes/b.md"])
        #expect(try manifest(second).sharesData == true)
    }

    @Test func manifestHashesDescribeTheStoredFiles() async throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        try await backUp(destination(RecordingCloning()), at: first)

        let file = try #require(try manifest(first).files?.first)
        #expect(file.sha256 == "8ed3f6ad685b959ead7022518e1af76cd816f8e8ec7ccdda1ed4018e8f2223f8")
        #expect(file.size == 5)
    }

    @Test func movedFileIsClonedByContent() async throws {
        defer { temp.remove() }
        let cloning = RecordingCloning()
        try temp.file("vault/photo.jpg", "pixels")
        try await backUp(destination(cloning), at: first)

        try FileManager.default.createDirectory(at: temp.path("vault/2026"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temp.path("vault/photo.jpg"), to: temp.path("vault/2026/IMG_1.jpg"))
        try await backUp(destination(cloning), at: second)

        #expect(cloning.clonedTargets(relativeTo: snapshot(second)) == ["2026/IMG_1.jpg"])
        #expect(try content(second, "2026/IMG_1.jpg") == "pixels")
    }

    @Test func fileThatCameBackIsClonedFromAnOlderSnapshot() async throws {
        defer { temp.remove() }
        let cloning = RecordingCloning()
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/keep.md", "keep")
        try await backUp(destination(cloning), at: first)

        try FileManager.default.removeItem(at: temp.path("vault/a.md"))
        try await backUp(destination(cloning), at: second)
        #expect(!FileManager.default.fileExists(atPath: snapshot(second).appendingPathComponent("a.md").path))

        try temp.file("vault/a.md", "alpha")
        try await backUp(destination(cloning), at: third)

        let original = try #require(cloning.clones.first { $0.target.lastPathComponent == "a.md" }?.original)
        #expect(original.deletingLastPathComponent().lastPathComponent == name(first))
        #expect(try content(third, "a.md") == "alpha")
    }

    @Test func duplicatesInsideOnePayloadAreStoredOnce() async throws {
        defer { temp.remove() }
        let cloning = RecordingCloning()
        try temp.file("vault/a.jpg", "same")
        try temp.file("vault/b.jpg", "same")
        try await backUp(destination(cloning), at: first)

        #expect(cloning.clonedTargets(relativeTo: snapshot(first)) == ["b.jpg"])
        #expect(try content(first, "b.jpg") == "same")
    }

    @Test func editingACloneLeavesTheOriginalIntact() async throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        try await backUp(destination(RecordingCloning()), at: first)
        try await backUp(destination(RecordingCloning()), at: second)

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
        let old = SnapshotManifest(sourceId: UUID(), sourceName: "Obsidian", collectedAt: first, fileCount: 1, totalBytes: 5)
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

    @Test func failedCloneFallsBackToACopy() async throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        try await backUp(destination(RecordingCloning()), at: first)
        try await backUp(destination(RecordingCloning(.failing)), at: second)

        #expect(try content(second, "a.md") == "alpha")
        #expect(try manifest(second).files?.first?.sha256 == manifest(first).files?.first?.sha256)
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

        let manifests = try [first, second].map { date in
            try FileManager.default.attributesOfItem(atPath: snapshot(date).appendingPathComponent(SnapshotManifest.fileName).path)[.size] as! NSNumber
        }
        #expect(try await destination.usedBytes() == 5 + 3 + 7 + 2 + manifests.reduce(0) { $0 + $1.int64Value })
    }

    @Test func usedBytesCountsFullCopiesInFull() async throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "12345")
        let destination = destination(RecordingCloning(.unsupported))
        try await backUp(destination, at: first)
        try await backUp(destination, at: second)

        let manifests = try [first, second].map { date in
            try FileManager.default.attributesOfItem(atPath: snapshot(date).appendingPathComponent(SnapshotManifest.fileName).path)[.size] as! NSNumber
        }
        #expect(try await destination.usedBytes() == 10 + manifests.reduce(0) { $0 + $1.int64Value })
    }
}
