import Foundation
import Testing
@testable import BackupCore

/// Stands in for macOS: which disk a folder is on, as the test says.
final class FakeDisks: DiskLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var current: DiskLocation

    init(_ location: DiskLocation) {
        current = location
    }

    var location: DiskLocation {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func location(of url: URL) -> DiskLocation {
        location
    }
}

/// A folder on an external disk is used only on the disk the person confirmed for it (4.2.1).
struct DiskIdentityTests {
    private let temp: TempDirectory
    private let date = Fixtures.date("2026-09-28 14:30:00")
    private let name = "2026-09-28_143000"
    private let mine = DiskIdentity(uuid: "11111111-AAAA-4AAA-8AAA-111111111111", name: "TEST-BE-DISK")
    private let stranger = DiskIdentity(uuid: "22222222-BBBB-4BBB-8BBB-222222222222", name: "TEST-BE-DISK")

    init() throws {
        temp = try TempDirectory()
        try temp.directory("disk")
        try temp.file("vault/a.md", "alpha")
    }

    private func destination(expecting disk: DiskIdentity?, on location: DiskLocation) -> LocalFolderDestination {
        LocalFolderDestination(root: temp.path("disk"), naming: Fixtures.naming, expectedDisk: disk, disks: FakeDisks(location)) { _ in
            Issue.record("Nothing goes to the Trash")
        }
    }

    private func manifest() -> SnapshotManifest {
        SnapshotManifest(sourceId: UUID(), sourceName: "Obsidian", collectedAt: date, fileCount: 1, totalBytes: 5)
    }

    private func write(to destination: LocalFolderDestination) async throws {
        try await destination.write(
            Payload(root: temp.path("vault"), collectedAt: date),
            manifest: manifest(),
            sourceSlug: "obsidian",
            snapshotName: name,
            reusingStoredFiles: false
        )
    }

    @Test func checkComparesTheConnectedDiskWithTheConfirmedOne() {
        defer { temp.remove() }
        let unreadable = DiskIdentity(uuid: nil, name: "TEST-BE-DISK")
        #expect(DiskCheck.of(.systemDisk, expected: nil) == .notNeeded)
        #expect(DiskCheck.of(.systemDisk, expected: mine) == .notNeeded)
        #expect(DiskCheck.of(.notConnected, expected: nil) == .notConfirmed(connected: nil))
        #expect(DiskCheck.of(.notConnected, expected: mine) == .notConnected)
        #expect(DiskCheck.of(.connected(mine), expected: nil) == .notConfirmed(connected: mine))
        #expect(DiskCheck.of(.connected(mine), expected: mine) == .confirmed)
        #expect(DiskCheck.of(.connected(DiskIdentity(uuid: mine.uuid, name: "Renamed")), expected: mine) == .confirmed)
        #expect(DiskCheck.of(.connected(stranger), expected: mine) == .otherDisk(stranger))
        #expect(DiskCheck.of(.connected(unreadable), expected: mine) == .otherDisk(unreadable))
        #expect(DiskCheck.of(.connected(mine), expected: unreadable) == .otherDisk(mine))
        #expect(DiskCheck.of(.connected(unreadable), expected: unreadable) == .confirmed)
        #expect(DiskCheck.of(.connected(stranger), expected: mine).connectedDisk == stranger)
        #expect(DiskCheck.of(.connected(mine), expected: nil).connectedDisk == mine)
        #expect(DiskCheck.of(.connected(mine), expected: mine).connectedDisk == nil)
        for expected in [nil, mine, unreadable] {
            #expect(DiskCheck.of(.unidentified(name: "TEST-BE-DISK"), expected: expected) == .unidentified(name: "TEST-BE-DISK"))
        }
        #expect(DiskCheck.of(.unidentified(name: "TEST-BE-DISK"), expected: nil).connectedDisk == nil)
        #expect(!DiskCheck.unidentified(name: "TEST-BE-DISK").allowsAccess)
        #expect(!DiskCheck.notConnected.allowsAccess)
    }

    @Test func folderOnTheConfirmedDiskIsUsed() async throws {
        defer { temp.remove() }
        let destination = destination(expecting: mine, on: .connected(mine))
        #expect(await destination.isAvailable())
        #expect(await destination.diskCheck() == .confirmed)
        try await write(to: destination)
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").map(\.name) == [name])
    }

    @Test func folderOnTheSystemDiskNeedsNoConfirmation() async throws {
        defer { temp.remove() }
        let destination = destination(expecting: nil, on: .systemDisk)
        #expect(await destination.isAvailable())
        #expect(await destination.diskCheck() == .notNeeded)
        try await write(to: destination)
        #expect(temp.exists("disk/obsidian/\(name)/a.md"))
    }

    @Test func diskWithAnUnreadableIdentityIsUsedOnceThatWasConfirmed() async throws {
        defer { temp.remove() }
        let unreadable = DiskIdentity(uuid: nil, name: "TEST-BE-DISK")
        try await write(to: destination(expecting: unreadable, on: .connected(unreadable)))
        #expect(temp.exists("disk/obsidian/\(name)/a.md"))
    }

    /// Whatever is there stays untouched and unread: not written, not deleted, not listed, not measured. A folder left in
    /// `/Volumes` on the system disk while the disk is away is refused too, even when the caller did not ask `isAvailable` first.
    @Test(arguments: [
        (DiskIdentity?.none, DiskLocation.connected(DiskIdentity(uuid: "22222222-BBBB-4BBB-8BBB-222222222222", name: "TEST-BE-DISK")), DestinationError.diskNotConfirmed),
        (DiskIdentity(uuid: "11111111-AAAA-4AAA-8AAA-111111111111", name: "TEST-BE-DISK"), .connected(DiskIdentity(uuid: "22222222-BBBB-4BBB-8BBB-222222222222", name: "TEST-BE-DISK")), .otherDisk(name: "TEST-BE-DISK")),
        (DiskIdentity(uuid: nil, name: "TEST-BE-DISK"), .connected(DiskIdentity(uuid: "22222222-BBBB-4BBB-8BBB-222222222222", name: "TEST-BE-DISK")), .otherDisk(name: "TEST-BE-DISK")),
        (DiskIdentity(uuid: nil, name: "TEST-BE-DISK"), .unidentified(name: "TEST-BE-DISK"), .diskUnidentified(name: "TEST-BE-DISK")),
        (DiskIdentity(uuid: "11111111-AAAA-4AAA-8AAA-111111111111", name: "TEST-BE-DISK"), .notConnected, .unavailable),
        (DiskIdentity?.none, .notConnected, .diskNotConfirmed),
    ])
    func folderOnAnUnconfirmedOrOtherDiskIsRefusedEverything(expected: DiskIdentity?, location: DiskLocation, refusal: DestinationError) async throws {
        defer { temp.remove() }
        let old = Fixtures.snapshot("2026-09-20 10:00:00")
        try temp.file("disk/obsidian/\(old.name)/_snapshot.json", "{}")
        try temp.file("disk/obsidian/2026-09-21_100000/_unfinished")
        let destination = destination(expecting: expected, on: location)

        #expect(await destination.isAvailable() == false)
        #expect(await destination.canShareUnchangedFiles() == nil)
        await #expect(throws: refusal) { try await write(to: destination) }
        await #expect(throws: refusal) { try await destination.delete(old, sourceSlug: "obsidian") }
        await #expect(throws: refusal) { try await destination.removeIncomplete(sourceSlug: "obsidian") }
        await #expect(throws: refusal) { try await destination.listSnapshots(sourceSlug: "obsidian") }
        await #expect(throws: refusal) { try await destination.owners(sourceSlug: "obsidian") }
        await #expect(throws: refusal) { try await destination.materialize(old, sourceSlug: "obsidian", scratch: temp.path("scratch")) }
        await #expect(throws: refusal) { try await destination.usedBytes() }
        #expect(temp.names(in: "disk/obsidian") == ["2026-09-20_100000", "2026-09-21_100000"])
    }

    @Test func diskWhoseIdentityCannotBeReadIsExplained() {
        defer { temp.remove() }
        #expect(DestinationError.diskUnidentified(name: "TEST-BE-DISK").localizedDescription
            == "Could not read the ID of the disk “TEST-BE-DISK”, so it is not known whether it is this destination’s disk. Nothing was read, written or deleted there. The app checks again on its own.")
    }

    /// Copies can be proven on the system disk and on a confirmed disk, connected or not; on an external disk without a
    /// confirmed one they cannot, whatever disk is there now.
    @Test func copiesAreProvableOnlyWhereTheDiskIsKnown() async throws {
        defer { temp.remove() }
        let cases: [(DiskIdentity?, DiskLocation, Bool)] = [
            (nil, .systemDisk, true),
            (mine, .connected(mine), true),
            (mine, .connected(stranger), true),
            (mine, .notConnected, true),
            (mine, .unidentified(name: "TEST-BE-DISK"), true),
            (nil, .connected(mine), false),
            (nil, .notConnected, false),
            (nil, .unidentified(name: "TEST-BE-DISK"), false),
        ]
        for (expected, location, verifiable) in cases {
            #expect(await destination(expecting: expected, on: location).isVerifiable() == verifiable, "\(String(describing: expected)) on \(location)")
        }
    }

    @Test func unconfirmedDiskThatIsNotConnectedIsUnavailable() async throws {
        defer { temp.remove() }
        let destination = destination(expecting: nil, on: .notConnected)
        #expect(await destination.isAvailable() == false)
        #expect(await destination.diskCheck() == .notConfirmed(connected: nil))
    }

    @Test func storeFactoryHandsTheConfirmedDiskToTheFolder() async throws {
        defer { temp.remove() }
        let disks = FakeDisks(.connected(stranger))
        let factory = DefaultDestinationStoreFactory(runner: FakeProcessRunner(), rclone: RcloneLocator(candidates: []), naming: Fixtures.naming, disks: disks)
        var destination = Fixtures.localDestination("HDD", at: temp.path("disk"))
        destination.disk = mine

        #expect(await factory.store(for: destination).diskCheck() == .otherDisk(stranger))
        disks.location = .connected(mine)
        #expect(await factory.store(for: destination).diskCheck() == .confirmed)
        #expect(await factory.store(for: Destination(name: "Cloud", kind: .rclone(remote: "r", path: "p"))).diskCheck() == .notNeeded)
    }

    @Test func destinationKeepsItsDiskInTheSettingsAndOlderSettingsHaveNone() throws {
        defer { temp.remove() }
        var destination = Fixtures.localDestination("HDD", at: temp.path("disk"))
        destination.disk = mine
        let data = try JSONCoding.encoder().encode(Config(destinations: [destination]))
        #expect(try JSONCoding.decoder().decode(Config.self, from: data).destinations == [destination])

        let unreadable = Destination(name: "HDD", kind: .localFolder(path: "/x"), disk: DiskIdentity(uuid: nil, name: "TEST-BE-DISK"))
        let kept = try JSONCoding.decoder().decode(Destination.self, from: JSONCoding.encoder().encode(unreadable))
        #expect(kept.disk == DiskIdentity(uuid: nil, name: "TEST-BE-DISK"))

        let legacy = """
        {"schemaVersion": 1, "sources": [], "destinations": [
          {"id": "\(UUID().uuidString)", "name": "HDD", "kind": {"localFolder": {"path": "/Volumes/TEST-BE-OLD/Backups"}}, "expectedEvery": {"always": {}}}
        ]}
        """
        let config = try JSONCoding.decoder().decode(Config.self, from: Data(legacy.utf8))
        #expect(config.destinations.map(\.disk) == [nil])
    }

    @Test func volumePlacementTellsTheSystemDiskFromVolumes() throws {
        defer { temp.remove() }
        try temp.directory("Volumes/TEST-BE-LEFTOVER/Backups")
        let mounts = VolumeMounts(volumesRoot: temp.path("Volumes").path)
        #expect(mounts.placement(of: temp.path("disk")) == .systemDisk)
        guard case let .volume(mountPoint, isMounted) = mounts.placement(of: temp.path("Volumes/TEST-BE-LEFTOVER/Backups")) else {
            Issue.record("A folder in Volumes is on a volume")
            return
        }
        #expect(mountPoint.lastPathComponent == "TEST-BE-LEFTOVER")
        #expect(isMounted == false)
        #expect(SystemDisks(mounts: mounts).location(of: temp.path("Volumes/TEST-BE-LEFTOVER/Backups")) == .notConnected)
        #expect(SystemDisks(mounts: mounts).location(of: temp.path("Volumes/TEST-BE-GONE/Backups")) == .notConnected)
        #expect(SystemDisks().location(of: URL(fileURLWithPath: NSHomeDirectory())) == .systemDisk)
    }
}
