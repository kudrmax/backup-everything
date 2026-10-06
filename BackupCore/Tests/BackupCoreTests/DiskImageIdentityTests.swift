import Foundation
import Testing
@testable import BackupCore

/// Real disks with made-up names, mounted in a folder of the test that stands for `/Volumes` (4.2.1).
struct DiskImageIdentityTests {
    private let temp: TempDirectory
    /// exFAT names are at most 11 characters long.
    private let volumeName = "TEST-BE-\(UUID().uuidString.prefix(3))"
    private let disks: SystemDisks
    private let time = FakeTimeSource(Fixtures.date("2026-09-28 10:00:00"))
    private let store: Store

    init() throws {
        temp = try TempDirectory()
        try temp.file("vault/a.md", "alpha")
        disks = SystemDisks(mounts: VolumeMounts(volumesRoot: temp.path("Volumes").path))
        store = Store(dataDirectory: temp.path("data"))
    }

    private var mountPoint: URL { temp.path("Volumes/\(volumeName)") }
    private var backups: URL { mountPoint.appendingPathComponent("Backups", isDirectory: true) }

    private func disk(_ format: DiskImage.Format) throws -> DiskImage {
        let disk = try DiskImage(format, at: mountPoint, name: volumeName)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        return disk
    }

    private func connectedDisk() throws -> DiskIdentity {
        guard case let .connected(identity) = disks.location(of: backups) else { throw DestinationError.unavailable }
        return identity
    }

    private func coordinator() -> BackupCoordinator {
        CoreAssembly.makeCoordinator(
            dataDirectory: temp.path("data"),
            workDirectory: temp.path("work"),
            timeZone: Fixtures.utc,
            time: time,
            disks: disks,
            trash: { _ in }
        )
    }

    private func confirm(_ identity: DiskIdentity, for destination: Destination) throws -> Destination {
        var config = try store.loadConfig()
        var confirmed = destination
        confirmed.disk = identity
        ConfigEditor().save(confirmed, in: &config)
        try store.saveConfig(config)
        return confirmed
    }

    private func copies() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: backups.appendingPathComponent("obsidian").path)) ?? []).sorted()
    }

    @Test(arguments: [DiskImage.Format.apfs, .exFAT])
    func connectedDiskIsRecognisedByItsVolumeUUID(_ format: DiskImage.Format) throws {
        defer { temp.remove() }
        let disk = try disk(format)
        defer { disk.detach() }
        let identity = try connectedDisk()
        #expect(identity.name == volumeName)
        #expect(identity.uuid.flatMap(UUID.init(uuidString:)) != nil)

        disk.detach()
        #expect(disks.location(of: backups) == .notConnected)
        try disk.attach()
        #expect(try connectedDisk() == identity)
    }

    @Test(arguments: [DiskImage.Format.apfs, .exFAT])
    func diskIsUsedOnlyOnceConfirmedAndOnlyThatDisk(_ format: DiskImage.Format) async throws {
        defer { temp.remove() }
        let first = try disk(format)
        defer { first.detach() }
        let destination = Fixtures.localDestination("Backup disk", at: backups)
        let source = Fixtures.source(steps: [.folder(temp.path("vault").path, excludes: [])], destinations: [destination], createdAt: time.now)
        try store.saveConfig(Config(sources: [source], destinations: [destination]))
        let configBefore = try Data(contentsOf: store.configURL)
        let coordinator = coordinator()

        _ = try await coordinator.tick()
        #expect(copies().isEmpty, "a disk nobody confirmed gets nothing")
        #expect(try store.loadState().hasDebt(sourceId: source.id, destinationId: destination.id))
        #expect(try Data(contentsOf: store.configURL) == configBefore, "nothing is confirmed by itself")

        var confirmed = try confirm(connectedDisk(), for: destination)
        time.advance(3_600)
        _ = try await coordinator.tick()
        #expect(copies() == ["2026-09-28_110000"])

        first.detach()
        try first.attach()
        time.advance(86_400)
        _ = try await coordinator.runNow(sourceId: source.id)
        #expect(copies() == ["2026-09-28_110000", "2026-09-29_110000"], "the same disk connected again is still it")

        first.detach()
        let second = try disk(format)
        defer { second.detach() }
        let strangerCopy = backups.appendingPathComponent("obsidian/2026-09-20_100000")
        try FileManager.default.createDirectory(at: strangerCopy, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: strangerCopy.appendingPathComponent(SnapshotManifest.fileName))
        let other = try connectedDisk()
        #expect(other.name == volumeName)
        #expect(!other.isSameDisk(as: try #require(confirmed.disk)))

        time.advance(86_400 * 8)
        let result = try await coordinator.runNow(sourceId: source.id)
        _ = try await coordinator.tick()
        #expect(copies() == ["2026-09-20_100000"], "a disk with the same name, or the disk reformatted, is neither written nor cleaned")
        #expect(result.notices.allSatisfy { if case .copiesMissing = $0 { false } else { true } })
        let factory = DefaultDestinationStoreFactory(runner: SystemProcessRunner(), rclone: RcloneLocator(candidates: []), naming: Fixtures.naming, disks: disks)
        #expect(await factory.store(for: confirmed).diskCheck() == .otherDisk(other))

        confirmed = try confirm(other, for: confirmed)
        #expect(await factory.store(for: confirmed).diskCheck() == .confirmed)
        time.advance(3_600)
        _ = try await coordinator.runNow(sourceId: source.id)
        #expect(copies().count == 2, "once confirmed, the disk gets copies again")
    }
}
