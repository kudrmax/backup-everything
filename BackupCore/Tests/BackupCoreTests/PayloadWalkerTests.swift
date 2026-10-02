import Darwin
import Foundation
import Testing
@testable import BackupCore

struct PayloadWalkerTests {
    private let temp: TempDirectory
    private let walker = PayloadWalker()
    private let date = Fixtures.date("2026-09-28 14:30:00")

    init() throws {
        temp = try TempDirectory()
    }

    @Test func listsFilesDirectoriesAndSymlinks() throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "12345")
        try temp.file("vault/sub/b.md", "123")
        try temp.directory("vault/empty")
        try FileManager.default.createSymbolicLink(at: temp.path("vault/link.md"), withDestinationURL: temp.path("vault/a.md"))

        let entries = try walker.entries(of: Payload(root: temp.path("vault"), collectedAt: date))
        #expect(entries.map(\.relativePath) == ["a.md", "empty", "link.md", "sub", "sub/b.md"])
        #expect(entries.map(\.kind) == [.file, .directory, .symlink, .directory, .file])
        #expect(walker.stats(of: entries) == PayloadStats(fileCount: 3, totalBytes: 8))
    }

    @Test func appliesExcludesToNamesAndPathsIncludingCyrillic() throws {
        defer { temp.remove() }
        try temp.file("vault/keep.md")
        try temp.file("vault/.trash/old.md")
        try temp.file("vault/.obsidian/workspace.json")
        try temp.file("vault/.obsidian/app.json")
        try temp.file("vault/Черновики/й.md")

        let payload = Payload(root: temp.path("vault"), excludes: [".trash", ".obsidian/workspace*.json", "черновики"], collectedAt: date)
        let files = try walker.entries(of: payload).filter { $0.kind == .file }.map(\.relativePath)
        #expect(files == [".obsidian/app.json", "keep.md"])
    }

    @Test func singleFilePayloadYieldsOneEntry() throws {
        defer { temp.remove() }
        let file = try temp.file("export.csv", "1234")
        let entries = try walker.entries(of: Payload(root: file, collectedAt: date))
        #expect(entries.map(\.relativePath) == ["export.csv"])
        #expect(walker.stats(of: entries) == PayloadStats(fileCount: 1, totalBytes: 4))
    }

    @Test func missingRootThrows() {
        defer { temp.remove() }
        let missing = temp.path("nope")
        #expect(throws: SourceError.pathMissing(missing.path)) {
            try walker.entries(of: Payload(root: missing, collectedAt: date))
        }
    }

    @Test func unreadableFolderIsAnError() throws {
        defer {
            Permissions.unlockTree(temp.url)
            temp.remove()
        }
        try temp.file("vault/a.md")
        try temp.file("vault/private/b.md")
        chmod(temp.path("vault/private").path, 0)
        #expect(throws: SourceError.unreadable(temp.path("vault/private").path)) {
            try walker.entries(of: Payload(root: temp.path("vault"), collectedAt: date))
        }
    }

    @Test func folderThatCanBeListedButNotEnteredIsAnError() throws {
        defer {
            Permissions.unlockTree(temp.url)
            temp.remove()
        }
        try temp.file("vault/listed/b.md")
        chmod(temp.path("vault/listed").path, 0o444)
        #expect(throws: SourceError.unreadable(temp.path("vault/listed").path)) {
            try walker.entries(of: Payload(root: temp.path("vault"), collectedAt: date))
        }
    }

    @Test func excludedUnreadableFolderIsNotRead() throws {
        defer {
            Permissions.unlockTree(temp.url)
            temp.remove()
        }
        try temp.file("vault/a.md")
        try temp.file("vault/private/b.md")
        chmod(temp.path("vault/private").path, 0)
        let entries = try walker.entries(of: Payload(root: temp.path("vault"), excludes: ["private"], collectedAt: date))
        #expect(entries.map(\.relativePath) == ["a.md"])
    }

    @Test func rootLinkStandsForWhatItPointsToAndInnerLinksStayLinks() throws {
        defer { temp.remove() }
        let file = try temp.file("real/export.csv", "1234")
        try FileManager.default.createSymbolicLink(at: temp.path("real/inner.csv"), withDestinationURL: file)
        try FileManager.default.createSymbolicLink(at: temp.path("today.csv"), withDestinationURL: file)
        try FileManager.default.createSymbolicLink(at: temp.path("vault"), withDestinationURL: temp.path("real"))

        let single = try walker.entries(of: Payload(root: temp.path("today.csv"), collectedAt: date))
        #expect(single.map(\.relativePath) == ["today.csv"])
        #expect(single.first?.url.lastPathComponent == "export.csv")
        #expect(walker.stats(of: single) == PayloadStats(fileCount: 1, totalBytes: 4))

        let folder = try walker.entries(of: Payload(root: temp.path("vault"), collectedAt: date))
        #expect(folder.map(\.relativePath) == ["export.csv", "inner.csv"])
        #expect(folder.map(\.kind) == [.file, .symlink])
    }

    @Test func namesExcludedAtTheTopStayDeeper() throws {
        defer { temp.remove() }
        try temp.file("copy/_snapshot.json")
        try temp.file("copy/_UNFINISHED")
        try temp.file("copy/site/_snapshot.json")
        let payload = Payload(root: temp.path("copy"), excludedAtTop: SnapshotManifest.serviceFileNames, collectedAt: date)
        #expect(try walker.entries(of: payload).map(\.relativePath) == ["site", "site/_snapshot.json"])
    }
}
