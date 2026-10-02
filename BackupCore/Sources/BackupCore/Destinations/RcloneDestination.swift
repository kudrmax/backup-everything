import Foundation

public struct RcloneDestination: DestinationStore {
    private static let directoryNotFoundExitCode: Int32 = 3
    private static let availabilityTimeout: TimeInterval = 15
    private static let errorTailLength = 2000

    private let executable: URL?
    private let remote: String
    private let path: String
    private let runner: any ProcessRunner
    private let naming: SnapshotNaming
    private let walker = PayloadWalker()

    public init(executable: URL?, remote: String, path: String, runner: any ProcessRunner, naming: SnapshotNaming) {
        self.executable = executable
        self.remote = remote.hasSuffix(":") ? String(remote.dropLast()) : remote
        self.path = path
        self.runner = runner
        self.naming = naming
    }

    public func isAvailable() async -> Bool {
        let arguments = ["lsf", "\(remote):", "--max-depth", "1", "--contimeout", "10s", "--retries", "1"]
        guard let result = try? await rclone(arguments, timeout: Self.availabilityTimeout) else { return false }
        return result.exitCode == 0 && !result.timedOut
    }

    public func listSnapshots(sourceSlug: String) async throws -> [Snapshot] {
        try await directories(containing: SnapshotManifest.fileName, in: sourceSlug).compactMap(naming.snapshot(named:))
    }

    private func directories(containing fileName: String, in sourceSlug: String) async throws -> [String] {
        let result = try await rclone([
            "lsf", try target(sourceSlug),
            "--files-only", "--recursive", "--max-depth", "2",
            "--include", "/*/\(fileName)",
        ])
        if result.exitCode == Self.directoryNotFoundExitCode { return [] }
        try check(result)
        return lines(result.stdout).compactMap { line in line.split(separator: "/").first.map(String.init) }
    }

    public func owners(sourceSlug: String) async throws -> [String: UUID] {
        let folder = try target(sourceSlug)
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("rclone-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let result = try await rclone(["copy", folder, scratch.path, "--include", "/*/\(SnapshotManifest.fileName)"])
        if result.exitCode == Self.directoryNotFoundExitCode { return [:] }
        try check(result)
        var owners: [String: UUID] = [:]
        for name in (try? fileManager.contentsOfDirectory(atPath: scratch.path)) ?? [] {
            owners[name] = SnapshotManifest.owner(of: scratch.appendingPathComponent(name, isDirectory: true))
        }
        return owners
    }

    public func removeIncomplete(sourceSlug: String) async throws {
        let result = try await rclone(["lsf", try target(sourceSlug), "--dirs-only"])
        if result.exitCode == Self.directoryNotFoundExitCode { return }
        try check(result)
        let complete = Set(try await listSnapshots(sourceSlug: sourceSlug).map(\.name))
        let unfinished = Set(try await directories(containing: SnapshotManifest.unfinishedMarker, in: sourceSlug))
        let directories = lines(result.stdout).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        for name in directories where naming.date(from: name) != nil && unfinished.contains(name) && !complete.contains(name) {
            try check(try await rclone(["purge", try target(sourceSlug, name)]))
        }
    }

    public func write(_ payload: Payload, manifest: SnapshotManifest, sourceSlug: String, snapshotName: String, reusingStoredFiles: Bool) async throws {
        let destination = try target(sourceSlug, snapshotName)
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("rclone-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        try await clearTheWay(to: destination)
        let markerURL = scratch.appendingPathComponent(SnapshotManifest.unfinishedMarker)
        try Data(SnapshotManifest.unfinishedNote.utf8).write(to: markerURL)
        try check(try await rclone(["copyto", markerURL.path, "\(destination)/\(SnapshotManifest.unfinishedMarker)"]))
        let root = payload.root.resolvingSymlinksInPath()
        if walker.isDirectory(payload) {
            let files = try walker.entries(of: payload).filter { $0.kind == .file }.map(\.relativePath)
            let listURL = scratch.appendingPathComponent("files.txt")
            try files.joined(separator: "\n").write(to: listURL, atomically: true, encoding: .utf8)
            try check(try await rclone(["copy", root.path, destination, "--files-from-raw", listURL.path]))
        } else {
            try check(try await rclone(["copyto", root.path, "\(destination)/\(payload.root.lastPathComponent)"]))
        }

        let manifestURL = scratch.appendingPathComponent(SnapshotManifest.fileName)
        try JSONCoding.encoder().encode(manifest).write(to: manifestURL)
        try check(try await rclone(["copyto", manifestURL.path, "\(destination)/\(SnapshotManifest.fileName)"]))
        try check(try await rclone(["deletefile", "\(destination)/\(SnapshotManifest.unfinishedMarker)"]))
    }

    /// Spec 4.3: an unfinished attempt under the same name is purged, any other folder there stops the write untouched.
    private func clearTheWay(to destination: String) async throws {
        let result = try await rclone(["lsf", destination])
        if result.exitCode == Self.directoryNotFoundExitCode { return }
        try check(result)
        let entries = Set(lines(result.stdout))
        guard !entries.isEmpty else { return }
        guard entries.contains(SnapshotManifest.unfinishedMarker), !entries.contains(SnapshotManifest.fileName) else {
            throw DestinationError.folderInTheWay(destination)
        }
        try check(try await rclone(["purge", destination]))
    }

    public func delete(_ snapshot: Snapshot, sourceSlug: String) async throws {
        guard naming.date(from: snapshot.name) != nil else { return }
        try check(try await rclone(["purge", try target(sourceSlug, snapshot.name)]))
    }

    public func materialize(_ snapshot: Snapshot, sourceSlug: String, scratch: URL) async throws -> URL {
        let remote = try target(sourceSlug, snapshot.name)
        let local = scratch.appendingPathComponent(snapshot.name, isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try check(try await rclone(["copy", remote, local.path]))
        return local
    }

    public func canShareUnchangedFiles() async -> Bool? {
        false
    }

    public func usedBytes() async throws -> Int64 {
        struct Size: Decodable {
            let bytes: Int64
        }
        let result = try await rclone(["size", location([]), "--json"])
        if result.exitCode == Self.directoryNotFoundExitCode { return 0 }
        try check(result)
        guard let size = try? JSONDecoder().decode(Size.self, from: Data(result.stdout.utf8)) else {
            throw DestinationError.commandFailed("Could not parse the output of rclone size.")
        }
        return size.bytes
    }

    private func target(_ sourceSlug: String, _ snapshotName: String? = nil) throws -> String {
        location([try Slug.folderName(sourceSlug)] + (snapshotName.map { [$0] } ?? []))
    }

    private func location(_ components: [String]) -> String {
        var base = path
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        let parts = (base.isEmpty ? [] : [base]) + components
        return "\(remote):" + parts.joined(separator: "/")
    }

    private func rclone(_ arguments: [String], timeout: TimeInterval? = nil) async throws -> ProcessResult {
        guard let executable else { throw DestinationError.rcloneMissing }
        return try await runner.run(executable: executable, arguments: arguments, environment: [:], timeout: timeout)
    }

    private func check(_ result: ProcessResult) throws {
        guard result.exitCode == 0 else {
            throw DestinationError.commandFailed(String(result.stderr.suffix(Self.errorTailLength)))
        }
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}
