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
}
