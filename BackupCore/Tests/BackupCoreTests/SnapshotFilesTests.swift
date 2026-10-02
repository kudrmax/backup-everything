import Darwin
import Foundation
import Testing
@testable import BackupCore

struct SnapshotFilesTests {
    private let temp: TempDirectory
    private let date = Fixtures.date("2026-09-28 14:30:00")

    init() throws {
        temp = try TempDirectory()
    }

    private func readOnly(_ relative: String) throws -> URL {
        let url = try temp.directory(relative)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
        return url
    }

    private func cleanUp(_ readOnly: String...) {
        for relative in readOnly {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path(relative).path)
        }
        temp.remove()
    }

    @Test func folderThatCannotBeCreatedIsAnError() throws {
        defer { cleanUp("locked") }
        let locked = try readOnly("locked")
        #expect(throws: POSIXError(.EACCES)) {
            try ExactNameFiles().createDirectories("a/b", in: locked.path)
        }
        #expect(temp.names(in: "locked").isEmpty)
    }

    @Test func existingFoldersAreReused() throws {
        defer { temp.remove() }
        try temp.file("base/a/keep.md", "keep")
        try ExactNameFiles().createDirectories("a/b", in: temp.path("base").path)
        #expect(temp.names(in: "base/a") == ["b", "keep.md"])
    }

    @Test func copyNeverOverwritesAndReportsMissingSource() throws {
        defer { temp.remove() }
        let source = try temp.file("source.md", "new")
        let target = try temp.file("target.md", "old")
        #expect(throws: POSIXError(.EEXIST)) {
            try ExactNameFiles().copy(source.path, to: target.path)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
        #expect(throws: POSIXError(.ENOENT)) {
            try ExactNameFiles().copy(temp.path("missing.md").path, to: temp.path("copy.md").path)
        }
        #expect(!temp.exists("copy.md"))
    }

    @Test func writerFailsWhenTheCopyFolderIsNotWritable() throws {
        defer { cleanUp("copy") }
        try temp.file("vault/a.md", "alpha")
        let copy = try readOnly("copy")
        let entries = try PayloadWalker().entries(of: Payload(root: temp.path("vault"), collectedAt: date))
        #expect(throws: POSIXError(.EACCES)) {
            try SnapshotWriter(cloning: APFSCloning()).write(entries, into: copy, reusing: .empty)
        }
    }

    @Test func cloneNeverReplacesAnExistingFile() throws {
        defer { temp.remove() }
        let original = try temp.file("original.md", "original")
        let existing = try temp.file("existing.md", "existing")
        #expect(throws: POSIXError(.EEXIST)) {
            try APFSCloning().clone(original, to: existing.path)
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "existing")
        #expect(throws: POSIXError(.ENOENT)) {
            try APFSCloning().clone(temp.path("missing.md"), to: temp.path("clone.md").path)
        }
    }

    @Test func cloneIsAnIndependentFileWithTheSameContent() throws {
        defer { temp.remove() }
        let original = try temp.file("original.md", "original")
        try APFSCloning().clone(original, to: temp.path("clone.md").path)
        try Data("edited".utf8).write(to: temp.path("clone.md"))
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
    }

    @Test func missingFolderDoesNotSupportClones() {
        defer { temp.remove() }
        #expect(APFSCloning().isSupported(at: temp.path("missing")) == false)
    }

    @Test func usageOfAMissingFolderIsAnError() {
        defer { temp.remove() }
        #expect(throws: DestinationError.unavailable) {
            try DestinationUsage().bytes(under: temp.path("missing"))
        }
    }

    @Test func usageCountsOnlyRegularFiles() throws {
        defer { temp.remove() }
        try temp.file("disk/a.md", String(repeating: "a", count: 10_000))
        try temp.directory("disk/empty")
        try FileManager.default.createSymbolicLink(atPath: temp.path("disk/link.md").path, withDestinationPath: "a.md")
        #expect(try DestinationUsage().bytes(under: temp.path("disk")) == temp.allocatedBytes("disk/a.md"))
    }

    @Test func storedFileReplacedByALinkIsNotAnOriginal() throws {
        defer { temp.remove() }
        let stored = try temp.file("snapshot/a.md", "alpha")
        let file = SnapshotFile(
            path: "a.md",
            size: 5,
            sha256: try ContentHash().sha256(of: stored),
            modified: try FileManager.default.attributesOfItem(atPath: stored.path)[.modificationDate] as! Date
        )
        let index = StoredContentIndex(snapshots: [(temp.path("snapshot"), SnapshotManifest(
            sourceId: UUID(), sourceName: "Obsidian", collectedAt: date, fileCount: 1, totalBytes: 5, files: [file]
        ))])
        #expect(index.original(sha256: file.sha256, size: 5) == stored)

        try FileManager.default.removeItem(at: stored)
        try temp.file("elsewhere.md", "alpha")
        try FileManager.default.createSymbolicLink(atPath: stored.path, withDestinationPath: temp.path("elsewhere.md").path)
        #expect(index.original(sha256: file.sha256, size: 5) == nil)
    }

    @Test func storedFileThatVanishedIsNotAnOriginal() throws {
        defer { temp.remove() }
        let stored = try temp.file("snapshot/a.md", "alpha")
        let file = SnapshotFile(path: "a.md", size: 5, sha256: try ContentHash().sha256(of: stored), modified: date)
        var index = StoredContentIndex.empty
        index.add(stored, file)
        try FileManager.default.removeItem(at: stored)
        #expect(index.hasContent(ofSize: 5))
        #expect(index.original(sha256: file.sha256, size: 5) == nil)
    }

    // MARK: Written files are whole

    @Test func copyOfAnotherSizeThanItsUnchangedOriginalIsAnError() throws {
        defer { temp.remove() }
        let source = try temp.file("source.md", "alpha")
        let copy = try temp.file("copy.md", "al")
        #expect(throws: DestinationError.copyMismatch(path: source.path, expected: 5, actual: 2)) {
            try LogicalSize().checkCopy(copy.path, of: source.path, sizeBefore: 5)
        }
        try LogicalSize().checkCopy(source.path, of: source.path, sizeBefore: 5)
    }

    @Test func copyOfAFileThatChangedWhileItWasCopiedIsAccepted() throws {
        defer { temp.remove() }
        let source = try temp.file("source.md", "alpha, appended")
        let copy = try temp.file("copy.md", "alpha")
        try LogicalSize().checkCopy(copy.path, of: source.path, sizeBefore: 5)
        #expect(throws: POSIXError(.ENOENT)) {
            try LogicalSize().of(temp.path("missing.md").path)
        }
    }

    @Test func metadataKeepsTheCompressionOfTheTarget() throws {
        defer { temp.remove() }
        let compressed = temp.path("compressed.txt")
        try Compression.write(Compression.sample, compressedAt: compressed)
        let plain = try temp.file("plain.txt", Compression.sample)
        try Permissions.lock(plain)
        defer { Permissions.unlockTree(temp.url) }

        try FileMetadata().apply(from: plain.path, to: compressed.path)

        #expect(Compression.isCompressed(compressed))
        #expect(try String(contentsOf: compressed, encoding: .utf8) == Compression.sample)
        #expect(try FileManager.default.attributesOfItem(atPath: compressed.path)[.immutable] as? Bool == true)
    }

    @Test func metadataDoesNotCompressAPlainTarget() throws {
        defer { temp.remove() }
        let compressed = temp.path("compressed.txt")
        try Compression.write(Compression.sample, compressedAt: compressed)
        let plain = try temp.file("plain.txt", Compression.sample)

        try FileMetadata().apply(from: compressed.path, to: plain.path)

        #expect(!Compression.isCompressed(plain))
        #expect(try String(contentsOf: plain, encoding: .utf8) == Compression.sample)
    }

    @Test func resourceForkCannotBeGivenToACompressedFile() throws {
        defer { temp.remove() }
        let compressed = temp.path("compressed.txt")
        try Compression.write(Compression.sample, compressedAt: compressed)
        let classic = try temp.file("classic.txt", Compression.sample)
        try Permissions.setAttribute(XATTR_RESOURCEFORK_NAME, value: "fork", on: classic)

        #expect(throws: POSIXError(.ENOTSUP)) {
            try FileMetadata().apply(from: classic.path, to: compressed.path)
        }
        #expect(try String(contentsOf: compressed, encoding: .utf8) == Compression.sample)
    }

    @Test func resourceForkIsGivenToAPlainFileLikeAnyAttribute() throws {
        defer { temp.remove() }
        let classic = try temp.file("classic.txt", "data")
        let stale = try temp.file("stale.txt", "data")
        try Permissions.setAttribute(XATTR_RESOURCEFORK_NAME, value: "fork", on: classic)
        try Permissions.setAttribute(XATTR_RESOURCEFORK_NAME, value: "old", on: stale)

        try FileMetadata().apply(from: classic.path, to: stale.path)
        #expect(try Permissions.attribute(XATTR_RESOURCEFORK_NAME, of: stale) == "fork")

        try FileMetadata().apply(from: try temp.file("bare.txt", "data").path, to: stale.path)
        #expect(throws: (any Error).self) { try Permissions.attribute(XATTR_RESOURCEFORK_NAME, of: stale) }
    }

    @Test func metadataOfAMissingItemIsAnError() throws {
        defer { temp.remove() }
        let file = try temp.file("a.md")
        #expect(throws: POSIXError(.ENOENT)) {
            try FileMetadata().apply(from: temp.path("missing.md").path, to: file.path)
        }
        #expect(throws: POSIXError(.ENOENT)) {
            try FileMetadata().apply(from: file.path, to: temp.path("missing.md").path)
        }
    }

    // MARK: Files that vanish while they are copied

    @Test func entryThatVanishedBeforeItWasCopiedIsLeftOut() throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/gone/b.md", "beta")
        try temp.file("vault/c.md", "gamma")
        let entries = try PayloadWalker().entries(of: Payload(root: temp.path("vault"), collectedAt: date))
        try FileManager.default.removeItem(at: temp.path("vault/gone"))
        try FileManager.default.removeItem(at: temp.path("vault/c.md"))

        let written = try SnapshotWriter(cloning: APFSCloning()).write(entries, into: try temp.directory("copy"), reusing: .empty)

        #expect(written.map(\.path) == ["a.md"])
        #expect(temp.names(in: "copy") == ["a.md", "gone"])
        #expect(temp.names(in: "copy/gone").isEmpty)
    }
}
