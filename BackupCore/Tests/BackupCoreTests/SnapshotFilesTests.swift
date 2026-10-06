import Darwin
import Foundation
import Testing
@testable import BackupCore

/// Copying with Apple's engine, checking the copy against the listing, clones and the space copies take.
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

    private func listing(_ relative: String = "vault", excludes: [String] = []) throws -> PayloadListing {
        try PayloadWalker().listing(of: Payload(root: temp.path(relative), excludes: excludes, collectedAt: date))
    }

    private func modified(_ url: URL) -> timespec {
        var info = stat()
        lstat(url.path, &info)
        return info.st_mtimespec
    }

    // MARK: Copying

    @Test func exclusionsAreLeftOutWithTheirFolders() throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/cache/big.bin", "bytes")
        try temp.file("vault/notes/b.tmp", "tmp")
        try temp.file("vault/notes/b.md", "beta")
        try temp.file("vault/notes/cache/deep.bin", "bytes")
        let copy = try temp.directory("copy")

        try PayloadCopier().copy(try listing(excludes: ["cache", "*.tmp"]), into: copy.path)

        #expect(temp.names(in: "copy") == ["a.md", "notes"])
        #expect(temp.names(in: "copy/notes") == ["b.md"])
    }

    @Test func linksInReadOnlyAndLockedFoldersArriveAndFoldersKeepTheirDates() throws {
        defer { Permissions.removeTree(temp.url) }
        try temp.file("vault/ro/file.md", "file")
        try FileManager.default.createSymbolicLink(atPath: temp.path("vault/ro/link.md").path, withDestinationPath: "file.md")
        try temp.file("vault/locked/f.md", "f")
        try FileManager.default.createSymbolicLink(atPath: temp.path("vault/locked/l.md").path, withDestinationPath: "f.md")
        try FileManager.default.createSymbolicLink(atPath: temp.path("vault/top.md").path, withDestinationPath: "ro/file.md")
        #expect(chmod(temp.path("vault/ro").path, 0o555) == 0)
        try Permissions.lock(temp.path("vault/locked"))
        let copy = try temp.directory("copy")
        Thread.sleep(forTimeInterval: 1.1)

        try PayloadCopier().copy(try listing(), into: copy.path)

        for link in ["ro/link.md", "locked/l.md", "top.md"] {
            #expect(WrittenCopy.linkTarget(copy.appendingPathComponent(link).path) == WrittenCopy.linkTarget(temp.path("vault/\(link)").path))
        }
        for folder in ["ro", "locked"] {
            #expect(modified(copy.appendingPathComponent(folder)).tv_sec == modified(temp.path("vault/\(folder)")).tv_sec)
        }
        #expect(try FileManager.default.attributesOfItem(atPath: copy.appendingPathComponent("ro").path)[.posixPermissions] as? Int == 0o555)
        #expect(try FileManager.default.attributesOfItem(atPath: copy.appendingPathComponent("locked").path)[.immutable] as? Bool == true)
    }

    @Test func theTargetFolderKeepsItsOwnPermissionsAndLock() throws {
        defer { Permissions.removeTree(temp.url) }
        try temp.file("vault/a.md", "alpha")
        #expect(chmod(temp.path("vault").path, 0o555) == 0)
        try Permissions.lock(temp.path("vault"))
        let copy = try temp.directory("copy")

        try PayloadCopier().copy(try listing(), into: copy.path)

        let attributes = try FileManager.default.attributesOfItem(atPath: copy.path)
        #expect(attributes[.posixPermissions] as? Int == 0o755)
        #expect(attributes[.immutable] as? Bool == false)
        #expect(temp.names(in: "copy") == ["a.md"])
    }

    @Test func singleFileIsCopiedUnderItsName() throws {
        defer { temp.remove() }
        try temp.file("export.csv", "1;2")
        let copy = try temp.directory("copy")
        try PayloadCopier().copy(try listing("export.csv"), into: copy.path)
        #expect(try String(contentsOf: copy.appendingPathComponent("export.csv"), encoding: .utf8) == "1;2")
    }

    @Test func unreadableFileStopsTheCopy() throws {
        defer {
            chmod(temp.path("vault/b.md").path, 0o644)
            temp.remove()
        }
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/b.md", "beta")
        let listing = try listing()
        chmod(temp.path("vault/b.md").path, 0)

        #expect(throws: POSIXError(.EACCES)) { try PayloadCopier().copy(listing, into: try temp.directory("copy").path) }
    }

    @Test func writerFailsWhenTheCopyFolderIsNotWritable() throws {
        defer {
            chmod(temp.path("copy").path, 0o755)
            temp.remove()
        }
        try temp.file("vault/a.md", "alpha")
        let copy = try readOnly("copy")
        #expect(throws: POSIXError(.EACCES)) {
            try SnapshotWriter(cloning: APFSCloning()).write(try listing(), into: copy, sharingWith: nil)
        }
    }

    // MARK: Files that vanish while they are copied

    @Test func entryThatVanishedBeforeItWasCopiedIsLeftOut() throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/gone/b.md", "beta")
        try temp.file("vault/c.md", "gamma")
        let listing = try listing()
        try FileManager.default.removeItem(at: temp.path("vault/gone"))
        try FileManager.default.removeItem(at: temp.path("vault/c.md"))

        let written = try SnapshotWriter(cloning: APFSCloning()).write(listing, into: try temp.directory("copy"), sharingWith: nil)

        #expect(written.files.map(\.path) == ["a.md"])
        #expect(written.itemCount == 1)
        #expect(temp.names(in: "copy") == ["a.md"])
    }

    // MARK: The copy is checked against the listing

    @Test func copyMissingAnItemWhoseOriginalIsThereIsRefused() throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/b.md", "beta")
        let copy = try temp.directory("copy")
        let listing = try listing()
        try PayloadCopier().copy(listing, into: copy.path)
        try FileManager.default.removeItem(at: copy.appendingPathComponent("a.md"))

        #expect(throws: DestinationError.missingFromCopy(copy.path + "/a.md")) {
            try WrittenCopy(listing: listing).check(in: copy.path)
        }
    }

    @Test func copyOfAnotherSizeTypeOrLinkTargetIsRefused() throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        try temp.directory("vault/folder")
        try FileManager.default.createSymbolicLink(atPath: temp.path("vault/link").path, withDestinationPath: "a.md")
        let listing = try listing()
        let check = WrittenCopy(listing: listing)
        let copy = try temp.directory("copy")
        try PayloadCopier().copy(listing, into: copy.path)
        try check.check(in: copy.path)

        truncate(copy.path + "/a.md", 2)
        #expect(throws: DestinationError.changedInCopy(copy.path + "/a.md")) { try check.check(in: copy.path) }
        try temp.file("copy/a.md", "alpha")

        unlink(copy.path + "/link")
        symlink("folder", copy.path + "/link")
        #expect(throws: DestinationError.changedInCopy(copy.path + "/link")) { try check.check(in: copy.path) }
        unlink(copy.path + "/link")
        symlink("a.md", copy.path + "/link")

        rmdir(copy.path + "/folder")
        try temp.file("copy/folder", "a file now")
        #expect(throws: DestinationError.changedInCopy(copy.path + "/folder")) { try check.check(in: copy.path) }
    }

    @Test func fileThatChangedWhileItWasCopiedIsAcceptedAsRead() throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        let listing = try listing()
        let copy = try temp.directory("copy")
        try temp.file("vault/a.md", "alpha, appended")
        try PayloadCopier().copy(listing, into: copy.path)

        try WrittenCopy(listing: listing).check(in: copy.path)
    }

    /// Part of a file whose original vanished while it was copied is not taken for the whole: it leaves the copy, even
    /// locked, and is reported with the files that vanished before they were copied.
    @Test func partOfAFileThatVanishedWhileItWasCopiedLeavesTheCopy() throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/b.md", "beta")
        let listing = try listing()
        let copy = try temp.directory("copy")
        try PayloadCopier().copy(listing, into: copy.path)
        truncate(copy.path + "/a.md", 2)
        chflags(copy.path + "/a.md", UInt32(UF_IMMUTABLE))
        try FileManager.default.removeItem(at: temp.path("vault/a.md"))

        let vanished = try WrittenCopy(listing: listing).check(in: copy.path)

        #expect(vanished.map(\.relativePath) == ["a.md"])
        #expect(!temp.exists("copy/a.md"))
        #expect(temp.exists("copy/b.md"))
    }

    /// When the part cannot be taken out of the copy (its folder is read-only), the copy is not finished.
    @Test func partOfAVanishedFileThatCannotLeaveTheCopyLeavesItUnfinished() throws {
        defer {
            chmod(temp.path("copy/sub").path, 0o755)
            temp.remove()
        }
        try temp.file("vault/sub/a.md", "alpha")
        let listing = try listing()
        let copy = try temp.directory("copy")
        try PayloadCopier().copy(listing, into: copy.path)
        truncate(copy.path + "/sub/a.md", 2)
        chmod(copy.path + "/sub", 0o555)
        try FileManager.default.removeItem(at: temp.path("vault/sub/a.md"))

        #expect(throws: DestinationError.vanishedWhileCopied(copy.path + "/sub/a.md")) { try WrittenCopy(listing: listing).check(in: copy.path) }
    }

    @Test func partOfAFileFromAnEjectedDiskIsTheSourceGone() throws {
        let disk = try DiskImage(.apfs)
        defer {
            disk.detach()
            temp.remove()
        }
        let vault = disk.root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: false)
        try Data("alpha".utf8).write(to: vault.appendingPathComponent("a.md"))
        let listing = try PayloadWalker().listing(of: Payload(root: vault, collectedAt: date))
        let copy = try temp.directory("copy")
        try PayloadCopier().copy(listing, into: copy.path)
        truncate(copy.path + "/a.md", 2)
        disk.detach()

        #expect(throws: SourceError.sourceDisappeared(vault.path)) { try WrittenCopy(listing: listing).check(in: copy.path) }
    }

    @Test func partOfAFileWhoseOriginalCannotBeLookedAtIsAnError() throws {
        defer {
            chmod(temp.path("vault/sub").path, 0o755)
            temp.remove()
        }
        try temp.file("vault/sub/a.md", "alpha")
        let listing = try listing()
        let copy = try temp.directory("copy")
        try PayloadCopier().copy(listing, into: copy.path)
        truncate(copy.path + "/sub/a.md", 2)
        chmod(temp.path("vault/sub").path, 0)

        #expect(throws: POSIXError(.EACCES)) { try WrittenCopy(listing: listing).check(in: copy.path) }
    }

    @Test func itemThatLeftTheCopyBeforeItsListWasMadeLeavesTheCopyUnfinished() throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/b.md", "beta")
        let copy = try temp.directory("copy")
        let writer = SnapshotWriter(cloning: APFSCloning(), beforeReadingBack: { unlink(copy.path + "/b.md") })

        #expect(throws: DestinationError.missingFromCopy(copy.path + "/b.md")) {
            try writer.write(try listing(), into: copy, sharingWith: nil)
        }
    }

    @Test func fileOfTheCopyThatCannotBeReadBackIsNamed() throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        let copy = try temp.directory("copy")
        let writer = SnapshotWriter(cloning: APFSCloning(), beforeReadingBack: { chmod(copy.path + "/a.md", 0) })

        let error = #expect(throws: DestinationError.self) { try writer.write(try listing(), into: copy, sharingWith: nil) }
        guard case let .unreadableInCopy(path, _) = error else {
            Issue.record("unexpected \(String(describing: error))")
            return
        }
        #expect(path == copy.path + "/a.md")
        #expect(error?.localizedDescription.hasPrefix("“\(copy.path)/a.md” in the copy could not be read back") == true)
    }

    @Test func singleFileThatIsGoneIsTheSourceGone() throws {
        defer { temp.remove() }
        let file = try temp.file("export.csv", "1;2")
        let listing = try listing("export.csv")
        try FileManager.default.removeItem(at: file)

        #expect(throws: SourceError.sourceDisappeared(file.path)) { try PayloadCopier().copy(listing, into: try temp.directory("copy").path) }
    }

    @Test func copyThatCannotBeLookedIntoIsAnError() throws {
        defer {
            chmod(temp.path("copy/sub").path, 0o755)
            temp.remove()
        }
        try temp.file("vault/sub/a.md", "alpha")
        let listing = try listing()
        let copy = try temp.directory("copy")
        try PayloadCopier().copy(listing, into: copy.path)
        chmod(copy.path + "/sub", 0)

        #expect(throws: POSIXError(.EACCES)) { try WrittenCopy(listing: listing).check(in: copy.path) }
    }

    @Test func messagesOfAWrongCopyNameThePath() {
        #expect(DestinationError.missingFromCopy("/d/a.md").localizedDescription
            == "“/d/a.md” is missing from the copy although its original is still there. The copy was left unfinished so as not to pass for a complete one.")
        #expect(DestinationError.changedInCopy("/d/a.md").localizedDescription
            == "“/d/a.md” in the copy is not as its original (another type, size or link target). The copy was left unfinished so as not to pass for a complete one.")
        #expect(DestinationError.vanishedWhileCopied("/d/a.md").localizedDescription
            == "The original of “/d/a.md” vanished while it was being copied, so the copy holds only part of it. The copy was left unfinished so as not to pass for a complete one.")
        #expect(DestinationError.unreadableInCopy("/d/a.md", reason: "Permission denied.").localizedDescription
            == "“/d/a.md” in the copy could not be read back for the list of its files: Permission denied. The copy was left unfinished so as not to pass for a complete one.")
        #expect(DestinationError.leftoverInCopy("/d/.backup-everything-clone-1", reason: "Operation not permitted.").localizedDescription
            == "A temporary file “/d/.backup-everything-clone-1” made while saving space could not be removed from the copy: Operation not permitted. The copy was left unfinished so as not to pass for a complete one.")
    }

    // MARK: Clones and space

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
}
