import Foundation

/// How rsync reaches the receiver that runs as the backup account.
public struct ReceiverCommand: Sendable, Equatable {
    public let rsh: String

    public init(rsh: String) {
        self.rsh = rsh
    }

    public static let standard = ReceiverCommand(
        rsh: "/usr/bin/sudo -n -u \(SystemDestinationAccess.roleAccount) /usr/local/libexec/backup-everything/backup-receiver"
    )
}

/// Writes a copy with rsync: everything of the payload into the copy folder, unchanged files as hard links of the previous
/// copy, then the completion marker. Nothing is ever deleted or renamed.
public struct RsyncTransfer: Sendable {
    public static let homebrewRsync = URL(fileURLWithPath: "/opt/homebrew/bin/rsync")
    private static let errorTailLength = 2000
    private static let host = "backup"

    private let rsync: URL
    private let receiver: ReceiverCommand?
    private let runner: any ProcessRunner

    public init(rsync: URL, receiver: ReceiverCommand?, runner: any ProcessRunner) {
        self.rsync = rsync
        self.receiver = receiver
        self.runner = runner
    }

    public func write(_ payload: Payload, into copy: URL, linkDest: URL?) async throws {
        var arguments = ["-aAX", "--inplace", "--mkpath"]
        if let linkDest { arguments.append("--link-dest=\(linkDest.path)") }
        arguments += payload.excludes.map { "--exclude=\($0)" }
        let source = PayloadWalker().isDirectory(payload) ? payload.root.path + "/" : payload.root.path
        try await run(arguments + [source, destination(copy.path + "/")])
    }

    public func markComplete(_ copy: URL) async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("complete-\(UUID().uuidString)")
        try Data().write(to: marker)
        defer { try? FileManager.default.trashItem(at: marker, resultingItemURL: nil) }
        try await run([marker.path, destination(copy.path + "/" + CopyFolder.completionMarker)])
    }

    private func destination(_ path: String) -> String {
        receiver == nil ? path : "\(Self.host):\(path)"
    }

    private func run(_ arguments: [String]) async throws {
        guard FileManager.default.isExecutableFile(atPath: rsync.path) else { throw DestinationError.rsyncMissing }
        let rsh = receiver.map { ["--rsh=\($0.rsh)"] } ?? []
        let result = try await runner.run(executable: rsync, arguments: rsh + arguments, environment: [:], timeout: nil)
        guard result.exitCode == 0 else {
            throw DestinationError.commandFailed(String(result.stderr.suffix(Self.errorTailLength)))
        }
    }
}
