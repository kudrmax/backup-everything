import Foundation
import Testing
@testable import BackupCore

/// Reproductions of bugs found while raising coverage. Each test describes the behaviour the spec asks for and fails until the bug is fixed.
struct FoundBugsCoreCoverageTests {
    private let temp: TempDirectory
    private let date = Fixtures.date("2026-09-28 14:30:00")
    private let name = "2026-09-28_143000"

    init() throws {
        temp = try TempDirectory()
    }

    /// Spec 4.3: names inside a local copy match the original byte for byte. A source of several steps copies its folder
    /// through FileManager and URL, which store “й” as “и” plus a combining breve.
    @Test func folderStepKeepsNamesByteForByte() async throws {
        defer { temp.remove() }
        let composed = "Мой план".precomposedStringWithCanonicalMapping
        try temp.directory("vault")
        #expect(FileManager.default.createFile(atPath: temp.path("vault").path + "/" + composed + ".md", contents: Data("plan".utf8)))
        let source = StepsSource(
            sourceId: UUID(),
            steps: [.folder(temp.path("vault").path), .command("true", timeoutSeconds: 30)],
            stagingRoot: temp.path("staging"),
            runner: FakeProcessRunner()
        )

        let payload = try await source.collect(at: date)

        let names = try FileManager.default.contentsOfDirectory(atPath: payload.root.path)
        #expect(names.map { Array($0.utf8) } == [Array("\(composed).md".utf8)])
    }

    /// A catch-up copy is the same snapshot transferred as is. Files the person keeps under the names of the app's service files
    /// in subfolders are dropped from it, because the service files are excluded by name at any depth.
    @Test func catchUpCopyKeepsNestedFilesNamedLikeServiceFiles() async throws {
        defer { temp.remove() }
        try temp.directory("hdd")
        try temp.directory("ssd")
        try temp.file("vault/notes/_unfinished", "a note called _unfinished")
        try temp.file("vault/a.md", "alpha")
        let hdd = Fixtures.localDestination("HDD", at: temp.path("hdd"))
        let ssd = Fixtures.localDestination("SSD", at: temp.path("ssd"))
        let source = Fixtures.source(steps: [.folder(temp.path("vault").path)], destinations: [hdd, ssd])
        let stores = DefaultDestinationStoreFactory(runner: FakeProcessRunner(), rclone: RcloneLocator(candidates: []), naming: Fixtures.naming)
        let engine = BackupEngine(
            providers: DefaultSourceProviderFactory(runner: FakeProcessRunner(), stagingRoot: temp.path("staging"), inbox: ManualExportInbox(pendingRoot: temp.path("pending"), naming: Fixtures.naming)),
            stores: stores,
            retention: RetentionPolicy(timeZone: Fixtures.utc),
            naming: Fixtures.naming,
            time: FakeTimeSource(date)
        )
        let original = await engine.run(source: source, destinations: [hdd], trigger: .scheduled)
        let snapshot = Snapshot(name: try #require(original.snapshotName), date: date)

        _ = await engine.copy(snapshot, of: source, from: hdd, to: [ssd])

        #expect(temp.exists("ssd/obsidian/\(snapshot.name)/notes/_unfinished"))
    }
}

