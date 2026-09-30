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
        guard let template = BundledTemplates.all.first(where: { $0.id == "claude" }),
              case let .steps(steps) = template.kind else { return [] }
        return steps
    }

    private var command: String {
        guard case let .command(command, _) = steps.last?.kind else { return "" }
        return command
    }

    private func manifest(_ files: [(name: String, link: String)], createdAt: String = "2026-01-15T00:00:00.231593+00:00") throws {
        let entries = files.map { #"{"export_url":"\#($0.link)","filename":"\#($0.name)","category":"x","part":0}"# }
        try temp.file("input/manifest-abc.json", #"{"created_at":"\#(createdAt)","total_files":\#(files.count),"data_files":[\#(entries.joined(separator: ","))],"version":"1.0"}"#)
    }

    /// Подменяет браузер: записывает открытую ссылку и «скачивает» файл с тем именем, которое задано для ссылки.
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

    /// Login-оболочка может дописать в вывод своё, поэтому ошибки сверяются по концу текста.
    private func failure(opener: String) async -> String {
        do {
            _ = try await run(opener: opener)
            Issue.record("ожидалась ошибка шага")
            return ""
        } catch let SourceError.commandFailed(_, output) {
            return output
        } catch {
            Issue.record("неожиданная ошибка: \(error)")
            return ""
        }
    }

    private func stillDownloading(_ name: String) -> String {
        "Не скачались архивы: \(name). Ещё не докачались: \(name). Когда загрузка закончится, повторите шаг; если она прервалась, удалите незавершённые файлы в папке загрузок и повторите шаг."
    }

    private var opened: [String] {
        ((try? String(contentsOf: temp.path("opened.txt"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private let two = [(name: "memories-000.zip", link: "https://claude.ai/export/x/download/1"), (name: "projects-000.zip", link: "https://claude.ai/export/x/download/2")]

    @Test func templateIsAManualStepFollowedByACommand() {
        #expect(steps.map(\.name) == ["Запросить экспорт", "Скачать архивы"])
        guard case let .manual(instructions, watchPath, filePattern, includeInCopy) = steps.first?.kind,
              case let .command(_, timeoutSeconds) = steps.last?.kind else {
            Issue.record("неожиданные шаги")
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

        #expect(tail.hasSuffix("скачано 2 из 2"))
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

        #expect(await failure(opener: opener).hasSuffix("В папке загрузок лежит старый файл memories-000.zip. Уберите его и повторите шаг."))
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
        #expect(output.hasSuffix("Не скачались архивы: projects-000.zip. Запросите экспорт заново."))
        #expect(output.components(separatedBy: "скачано 1 из 2").count == 2, "ход работы печатается только при изменении")
        #expect(temp.names(in: "Downloads").isEmpty)
        #expect(temp.names(in: "output") == ["memories-000.zip"], "скачанное остаётся в копии и не потребуется при повторе шага")
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
        #expect(await failure(opener: "/usr/bin/true").hasSuffix("Манифест экспорта не найден."))
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
