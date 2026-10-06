import BackupCore
import Foundation
@testable import BackupEverything

/// A temporary folder that goes to the Trash when the test is over.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("BackupEverythingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    func folder(_ name: String) throws -> URL {
        let folder = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @discardableResult
    func file(_ name: String, in folder: URL? = nil, contents: String = "content") throws -> URL {
        let file = (folder ?? url).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }
}

/// A defaults domain of its own, removed when the test is over: tests never touch the app’s settings.
final class TestDefaults {
    let suiteName = "local.backup-everything.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// Waits for something that happens in a background task, failing after `timeout` seconds.
@MainActor
func eventually(timeout: TimeInterval = 5, _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

struct FakeProcessRunner: ProcessRunner {
    let result: ProcessResult

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        result
    }
}

@MainActor
final class FakeFinder: FileRevealing {
    private(set) var opened: [URL] = []
    private(set) var selected: [URL] = []

    func open(_ url: URL) {
        opened.append(url)
    }

    func select(_ url: URL) {
        selected.append(url)
    }
}

/// Stands in for macOS: which disk every folder is on, as the test says.
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

/// Stands in for macOS: the folders of unplugged disks, by path; everything else is on the system disk.
final class UnpluggedDisks: DiskLocating, @unchecked Sendable {
    static let disk = DiskIdentity(uuid: "33333333-CCCC-4CCC-8CCC-333333333333", name: "TEST-BE-OFF")
    private let lock = NSLock()
    private var folders: Set<String> = []

    func unplug(_ path: String) {
        lock.withLock { _ = folders.insert(path) }
    }

    func location(of url: URL) -> DiskLocation {
        lock.withLock { folders.contains(url.path) } ? .notConnected : .systemDisk
    }
}

extension ModelFixture {
    /// A destination on a disk that is confirmed and unplugged.
    func unpluggedDisk(_ name: String, every days: Int? = nil, on disks: UnpluggedDisks) throws -> Destination {
        var destination = try disk(name, connected: false, every: days)
        destination.disk = UnpluggedDisks.disk
        if case let .localFolder(path) = destination.kind { disks.unplug(path) }
        return destination
    }
}
