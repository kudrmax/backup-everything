import Foundation
import Testing
@testable import BackupCore

struct ClaudeTemplateTests {
    private let temp: TempDirectory
    private let shell = ShellCommand(runner: SystemProcessRunner())

    init() throws {
        temp = try TempDirectory()
        for folder in ["input", "output", "Downloads"] { try temp.directory(folder) }
        try temp.file("opened.txt", "")
    }

    private var steps: [SourceStep] {
        BundledTemplates.all.first { $0.id == "claude" }?.steps ?? []
    }

    private var command: String {
        guard case let .command(command, _) = steps.last?.kind else { return "" }
        return command
    }

    private func manifest(_ files: [(name: String, link: String)], createdAt: String = "2026-01-15T00:00:00.231593+00:00") throws {
        let entries = files.map { #"{"export_url":"\#($0.link)","filename":"\#($0.name)","category":"x","part":0}"# }
        try temp.file("input/manifest-abc.json", #"{"created_at":"\#(createdAt)","total_files":\#(files.count),"data_files":[\#(entries.joined(separator: ","))],"version":"1.0"}"#)
    }

    /// Stands in for the browser: records the opened link and “downloads” the file with the name given for that link.
    private func fakeBrowser(_ downloads: [String: String]) throws -> String {
        let cases = downloads.map { #"  "\#($0.key)") echo data > "\#(temp.path("Downloads").path)/\#($0.value)" ;;"# }.joined(separator: "\n")
        let script = """
        #!/bin/zsh
        echo "$1" >> "\(temp.path("opened.txt").path)"
        case "$1" in
        \(cases)
        esac
        """
        let url = try temp.file("fake-open", script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func run(opener: String) async throws -> String {
        try await shell.run(command, timeoutSeconds: 60, environment: [
            "BACKUP_INPUT_DIR": temp.path("input").path,
            "BACKUP_OUTPUT_DIR": temp.path("output").path,
            "BACKUP_DOWNLOADS_DIR": temp.path("Downloads").path,
            "BACKUP_OPEN_COMMAND": opener,
            "BACKUP_WAIT_SECONDS": "3",
        ]) { _ in }
    }

    /// A login shell may add its own output, so errors are matched by the end of the text.
    private func failure(opener: String) async -> String {
        do {
            _ = try await run(opener: opener)
            Issue.record("expected the step to fail")
            return ""
        } catch let SourceError.commandFailed(_, output) {
            return output
        } catch {
            Issue.record("unexpected error: \(error)")
            return ""
        }
    }

    private func stillDownloading(_ name: String) -> String {
        "Archives not downloaded: \(name). Still downloading: \(name). When the download finishes, repeat the step; if it was interrupted, delete the unfinished files in the downloads folder and repeat the step."
    }

    private var opened: [String] {
        ((try? String(contentsOf: temp.path("opened.txt"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private let two = [(name: "memories-000.zip", link: "https://claude.ai/export/x/download/1"), (name: "projects-000.zip", link: "https://claude.ai/export/x/download/2")]

    @Test func templateIsAManualStepFollowedByACommand() {
        #expect(steps.map(\.name) == ["Request export", "Download archives"])
        guard case let .file(instructions, watchPath, filePattern, .single, includeInCopy, true) = steps.first?.kind,
              case let .command(_, timeoutSeconds) = steps.last?.kind else {
            Issue.record("unexpected steps")
            return
        }
        #expect(watchPath == "~/Downloads")
        #expect(filePattern == "manifest-*.json")
        #expect(!includeInCopy)
        #expect(instructions.contains("claude.ai"))
        #expect(timeoutSeconds == 3600)
    }

    @Test func everyArchiveIsOpenedAndMovedIntoTheCopy() async throws {
        defer { temp.remove() }
        try manifest(two)
        let opener = try fakeBrowser(["https://claude.ai/export/x/download/1": "memories-000.zip", "https://claude.ai/export/x/download/2": "projects-000.zip"])

        let tail = try await run(opener: opener)

        #expect(tail.hasSuffix("downloaded 2 of 2"))
        #expect(opened == two.map(\.link))
        #expect(temp.names(in: "output") == ["memories-000.zip", "projects-000.zip"])
        #expect(temp.names(in: "Downloads").isEmpty)
        #expect(temp.names(in: "input") == ["manifest-abc.json"])
    }

    @Test func archiveDownloadedEarlierIsNotOpenedAgain() async throws {
        defer { temp.remove() }
        try manifest(two)
        try temp.file("Downloads/memories-000.zip", "data")
        let opener = try fakeBrowser(["https://claude.ai/export/x/download/2": "projects-000.zip"])

        _ = try await run(opener: opener)

        #expect(opened == ["https://claude.ai/export/x/download/2"])
        #expect(temp.names(in: "output") == ["memories-000.zip", "projects-000.zip"])
    }

    @Test func staleArchiveStopsTheStepBeforeAnyLinkIsOpened() async throws {
        defer { temp.remove() }
        try manifest(two)
        let old = Fixtures.date("2026-01-01 00:00:00")
        try temp.file("Downloads/memories-000.zip", "old", modified: old)
        let opener = try fakeBrowser(["https://claude.ai/export/x/download/2": "projects-000.zip"])

        #expect(await failure(opener: opener).hasSuffix("The downloads folder has an old file memories-000.zip. Remove it and repeat the step."))
        #expect(opened.isEmpty)
        #expect(temp.names(in: "Downloads") == ["memories-000.zip"])
        #expect(temp.names(in: "output").isEmpty)
    }

    @Test func halfDownloadedArchiveIsNotTaken() async throws {
        defer { temp.remove() }
        try manifest([two[0]])
        try temp.file("Downloads/memories-000.zip", "partial")
        try temp.file("Downloads/memories-000.zip.part", "partial")

        #expect(await failure(opener: "/usr/bin/true").hasSuffix(stillDownloading("memories-000.zip")))
        #expect(opened.isEmpty)
        #expect(temp.names(in: "output").isEmpty)
        #expect(temp.names(in: "Downloads") == ["memories-000.zip", "memories-000.zip.part"])
    }

    @Test func missingArchivesAreNamedInTheError() async throws {
        defer { temp.remove() }
        try manifest(two)
        let opener = try fakeBrowser(["https://claude.ai/export/x/download/1": "memories-000.zip"])

        let output = await failure(opener: opener)
        #expect(output.hasSuffix("Archives not downloaded: projects-000.zip. Request the export again."))
        #expect(output.components(separatedBy: "downloaded 1 of 2").count == 2, "progress is printed only when it changes")
        #expect(temp.names(in: "Downloads").isEmpty)
        #expect(temp.names(in: "output") == ["memories-000.zip"], "what was downloaded stays in the copy and is not needed again when the step is repeated")
    }

    @Test func archiveNameFromTheManifestCannotEscapeTheFolders() async throws {
        defer { temp.remove() }
        try manifest([(name: "../../evil.zip", link: "https://claude.ai/export/x/download/1")])
        let opener = try fakeBrowser(["https://claude.ai/export/x/download/1": "evil.zip"])

        _ = try await run(opener: opener)

        #expect(temp.names(in: "output") == ["evil.zip"])
        #expect(!temp.exists("evil.zip"))
    }

    @Test func stepFailsWithoutAManifest() async throws {
        defer { temp.remove() }
        #expect(await failure(opener: "/usr/bin/true").hasSuffix("Export manifest not found."))
    }

    @Test func archiveAlreadyInTheCopyIsNotOpenedAgain() async throws {
        defer { temp.remove() }
        try manifest(two)
        try temp.file("output/memories-000.zip", "data")
        let opener = try fakeBrowser(["https://claude.ai/export/x/download/2": "projects-000.zip"])

        _ = try await run(opener: opener)

        #expect(opened == ["https://claude.ai/export/x/download/2"])
        #expect(temp.names(in: "output") == ["memories-000.zip", "projects-000.zip"])
    }

    @Test func chromeDownloadInProgressIsNeitherReopenedNorTakenForAStaleFile() async throws {
        defer { temp.remove() }
        try manifest([two[0]])
        try temp.file("Downloads/memories-000.zip", "")
        try temp.file("Downloads/memories-000.zip.crdownload", "partial")
        let opener = try fakeBrowser([:])

        #expect(await failure(opener: opener).hasSuffix(stillDownloading("memories-000.zip")))
        #expect(opened.isEmpty)
        #expect(temp.names(in: "Downloads") == ["memories-000.zip", "memories-000.zip.crdownload"])
    }
}
