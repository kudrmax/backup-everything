import Darwin
import Foundation
import Testing
@testable import BackupCore

/// Reproductions of data-safety bugs found in review. Every test here fails until its bug is fixed.
@Suite(.serialized)
struct FoundBugsDataSafetyTests {
    private let temp: TempDirectory
    private let first = Fixtures.date("2026-09-01 10:00:00")
    private let second = Fixtures.date("2026-09-08 10:00:00")

    init() throws {
        temp = try TempDirectory()
        try temp.directory("disk")
        try temp.directory("Trash")
    }

    private func cleanUp() {
        Permissions.unlockTree(temp.url)
        temp.remove()
    }

    private func destination(_ folder: String = "disk", cloning: any FileCloning = APFSCloning()) -> LocalFolderDestination {
        let trashFolder = temp.path("Trash")
        return LocalFolderDestination(root: temp.path(folder), naming: Fixtures.naming, cloning: cloning) { url in
            try FileManager.default.moveItem(at: url, to: trashFolder.appendingPathComponent(UUID().uuidString))
        }
    }

    private func manifest(_ date: Date, sourceId: UUID = UUID(), payload: Payload) throws -> SnapshotManifest {
        let stats = PayloadWalker().stats(of: try PayloadWalker().entries(of: payload))
        return SnapshotManifest(sourceId: sourceId, sourceName: "Obsidian", collectedAt: date, fileCount: stats.fileCount, totalBytes: stats.totalBytes)
    }

    private func backUp(
        _ root: URL,
        to destination: LocalFolderDestination,
        at date: Date,
        slug: String = "obsidian",
        sourceId: UUID = UUID(),
        savesSpace: Bool = true
    ) async throws {
        let payload = Payload(root: root, collectedAt: date)
        try await destination.write(
            payload,
            manifest: try manifest(date, sourceId: sourceId, payload: payload),
            sourceSlug: slug,
            snapshotName: Fixtures.naming.name(for: date),
            reusingStoredFiles: savesSpace
        )
    }

    private func snapshotPath(_ date: Date, slug: String = "obsidian", in folder: String = "disk") -> String {
        "\(folder)/\(slug)/\(Fixtures.naming.name(for: date))"
    }

    // MARK: Copies of another source

    @Test func newSourceWithTheNameOfARemovedOnePrunesTheOldSourcesCopies() async throws {
        defer { cleanUp() }
        let editor = ConfigEditor()
        var config = Config()
        let removed = editor.makeSource(name: "Photos", steps: [.folder("/tmp/none")], now: first, in: config)
        editor.save(removed, in: &config)
        try temp.file("vault/a.jpg", "old photo")
        let oldDays = ["2026-09-01 10:00:00", "2026-09-02 10:00:00", "2026-09-03 10:00:00"].map(Fixtures.date)
        for day in oldDays {
            try await backUp(temp.path("vault"), to: destination(), at: day, slug: removed.slug, sourceId: removed.id)
        }
        editor.removeSource(removed.id, from: &config)

        let disk = Fixtures.localDestination("HDD", at: temp.path("disk"))
        var fresh = editor.makeSource(name: "Photos", steps: [.folder("/tmp/none")], now: second, in: config)
        fresh.retention = RetentionRules(daily: 1, weekly: 0, monthly: 0, yearly: 0)
        fresh.destinationIds = [disk.id]
        #expect(fresh.slug == removed.slug)

        try temp.file("new/b.jpg", "new photo")
        let provider = FakeSourceProvider(result: .success(Payload(root: temp.path("new"), collectedAt: second)))
        let stores = LocalStores(trash: temp.path("Trash"), provider: provider)
        let engine = BackupEngine(
            providers: stores,
            stores: stores,
            retention: RetentionPolicy(timeZone: Fixtures.utc),
            naming: Fixtures.naming,
            time: FakeTimeSource(second)
        )
        _ = await engine.run(source: fresh, destinations: [disk], trigger: .scheduled)

        for day in oldDays {
            #expect(temp.exists(snapshotPath(day, slug: removed.slug)), "copy of the removed source was deleted by the new source's rules")
        }
    }

    // MARK: Names without a time zone

    @Test func copyNamesAreAmbiguousWhenClocksGoBackSoTheFresherCopyOfTheDayIsDeleted() throws {
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let naming = SnapshotNaming(timeZone: berlin)
        let earlier = Fixtures.date("2026-10-25 00:50:00")
        let later = Fixtures.date("2026-10-25 01:10:00")
        let nextDay = Fixtures.date("2026-10-26 09:00:00")
        let listed = [earlier, later, nextDay].map { naming.snapshot(named: naming.name(for: $0))! }

        #expect(listed[0].date == earlier, "02:50 before clocks went back is read as 02:50 after, later than 02:10 after")
        let doomed = RetentionPolicy(timeZone: berlin)
            .snapshotsToDelete(listed, rules: RetentionRules(daily: 2, weekly: 0, monthly: 0, yearly: 0))
        #expect(doomed.map(\.name) == [naming.name(for: earlier)], "the latest copy of 25 October must stay")
    }

    // MARK: Cloud

    @Test func cloudCopyIsWrittenIntoAFolderInTheWayInsteadOfRefusing() async throws {
        defer { cleanUp() }
        let date = Fixtures.date("2026-09-28 14:30:00")
        let name = Fixtures.naming.name(for: date)
        let file = try temp.file("export.csv", "1;2")
        let runner = FakeProcessRunner { call in
            if call.arguments.first == "lsf", call.arguments.contains(where: { $0.hasSuffix("/finance/\(name)") || $0.hasSuffix("/finance") }) {
                return ProcessResult(exitCode: 0, stdout: "\(name)/\nold-export.csv\n")
            }
            return ProcessResult(exitCode: 0)
        }
        let cloud = RcloneDestination(
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/rclone"),
            remote: "gdrive",
            path: "backups",
            runner: runner,
            naming: Fixtures.naming
        )
        let payload = Payload(root: file, collectedAt: date)

        await #expect(throws: DestinationError.self, "spec 4.3: a folder without the mark under the copy name is in the way, nothing is written") {
            try await cloud.write(payload, manifest: try manifest(date, payload: payload), sourceSlug: "finance", snapshotName: name, reusingStoredFiles: false)
        }
    }

}

private struct LocalStores: SourceProviderFactory, DestinationStoreFactory {
    let trash: URL
    var provider = FakeSourceProvider(result: .failure(SourceError.emptyResult))

    func provider(for source: Source) -> any SourceProvider { provider }

    func store(for destination: Destination) -> any DestinationStore {
        guard case let .localFolder(path) = destination.kind else { fatalError("local folders only") }
        let trash = self.trash
        return LocalFolderDestination(root: URL(fileURLWithPath: path), naming: Fixtures.naming) { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
        }
    }
}
