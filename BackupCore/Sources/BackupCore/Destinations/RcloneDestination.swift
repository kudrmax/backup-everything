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
        let result = try await rclone([
            "lsf", target(sourceSlug),
            "--files-only", "--recursive", "--max-depth", "2",
            "--include", "/*/\(SnapshotManifest.fileName)",
        ])
        if result.exitCode == Self.directoryNotFoundExitCode { return [] }
        try check(result)
        return lines(result.stdout).compactMap { line in
            line.split(separator: "/").first.flatMap { naming.snapshot(named: String($0)) }
        }
    }

    public func removeIncomplete(sourceSlug: String) async throws {
        let result = try await rclone(["lsf", target(sourceSlug), "--dirs-only"])
        if result.exitCode == Self.directoryNotFoundExitCode { return }
        try check(result)
        let complete = Set(try await listSnapshots(sourceSlug: sourceSlug).map(\.name))
        let directories = lines(result.stdout).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        for name in directories where naming.date(from: name) != nil && !complete.contains(name) {
            try check(try await rclone(["purge", target(sourceSlug, name)]))
        }
    }

    public func write(_ payload: Payload, manifest: SnapshotManifest, sourceSlug: String, snapshotName: String) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("rclone-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let destination = target(sourceSlug, snapshotName)
        var arguments = ["copy", payload.root.path, destination]
        if walker.isDirectory(payload) {
            let files = try walker.entries(of: payload).filter { $0.kind == .file }.map(\.relativePath)
            let listURL = scratch.appendingPathComponent("files.txt")
            try files.joined(separator: "\n").write(to: listURL, atomically: true, encoding: .utf8)
            arguments += ["--files-from-raw", listURL.path]
        }
        try check(try await rclone(arguments))

        let manifestURL = scratch.appendingPathComponent(SnapshotManifest.fileName)
        try JSONCoding.encoder().encode(manifest).write(to: manifestURL)
        try check(try await rclone(["copyto", manifestURL.path, "\(destination)/\(SnapshotManifest.fileName)"]))
    }

    public func delete(_ snapshot: Snapshot, sourceSlug: String) async throws {
        guard naming.date(from: snapshot.name) != nil else { return }
        try check(try await rclone(["purge", target(sourceSlug, snapshot.name)]))
    }

    public func materialize(_ snapshot: Snapshot, sourceSlug: String, scratch: URL) async throws -> URL {
        let local = scratch.appendingPathComponent(snapshot.name, isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try check(try await rclone(["copy", target(sourceSlug, snapshot.name), local.path]))
        return local
    }

    public func usedBytes() async throws -> Int64 {
        struct Size: Decodable {
            let bytes: Int64
        }
        let result = try await rclone(["size", target(), "--json"])
        if result.exitCode == Self.directoryNotFoundExitCode { return 0 }
        try check(result)
        guard let size = try? JSONDecoder().decode(Size.self, from: Data(result.stdout.utf8)) else {
            throw DestinationError.commandFailed("Could not parse the output of rclone size.")
        }
        return size.bytes
    }

    private func target(_ components: String...) -> String {
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
