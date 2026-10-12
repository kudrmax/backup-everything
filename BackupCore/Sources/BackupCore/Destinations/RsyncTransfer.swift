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

/// Writes a copy with rsync: everything of the payload into a new copy folder, unchanged files as hard links of earlier
/// folders, then the completion marker. Nothing is ever deleted or renamed.
public struct RsyncTransfer: Sendable {
    public static let homebrewRsync = URL(fileURLWithPath: "/opt/homebrew/bin/rsync")
    private static let errorTailLength = 2000
    private static let vanishedFiles: Int32 = 24
    private static let host = "backup"
    /// The copy belongs to the backup account; the person reads it through the group of the destination root.
    private static let groupReadable = "--chmod=Dg+rx,Fg+r"

    private let rsync: URL
    private let receiver: ReceiverCommand?
    private let runner: any ProcessRunner
    private let scratch: URL

    public init(rsync: URL, receiver: ReceiverCommand?, runner: any ProcessRunner, scratch: URL) {
        self.rsync = rsync
        self.receiver = receiver
        self.runner = runner
        self.scratch = scratch
    }

    /// rsync looks for an unchanged file in `linkDests` in the given order. Returns what rsync said when files vanished
    /// during the transfer (code 24): the rest is in the copy.
    public func write(_ payload: Payload, into copy: URL, linkDests: [URL]) async throws -> String? {
        var arguments = ["-aAX", "--inplace", "--mkpath", Self.groupReadable]
        arguments += linkDests.map { "--link-dest=\($0.path)" }
        arguments += payload.excludes.map { "--exclude=\($0)" }
        let isDirectory = PayloadWalker().isDirectory(payload)
        if !isDirectory { arguments.append("--copy-links") }
        let source = isDirectory ? payload.root.path + "/" : payload.root.path
        let result = try await run(arguments + [source, destination(copy.path + "/")])
        guard result.exitCode != Self.vanishedFiles else { return tail(of: result) }
        try check(result)
        return nil
    }

    public func markComplete(_ copy: URL) async throws {
        guard FileManager.default.isExecutableFile(atPath: rsync.path) else { throw DestinationError.rsyncMissing }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let marker = scratch.appendingPathComponent("complete")
        if !FileManager.default.fileExists(atPath: marker.path) { try Data().write(to: marker) }
        try check(try await run(["--inplace", marker.path, destination(copy.path + "/" + CopyFolder.completionMarker)]))
    }

    private func destination(_ path: String) -> String {
        receiver == nil ? path : "\(Self.host):\(path)"
    }

    private func run(_ arguments: [String]) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: rsync.path) else { throw DestinationError.rsyncMissing }
        let rsh = receiver.map { ["--rsh=\($0.rsh)"] } ?? []
        return try await runner.run(executable: rsync, arguments: rsh + arguments, environment: [:], timeout: nil)
    }

    private func check(_ result: ProcessResult) throws {
        guard result.exitCode == 0 else { throw DestinationError.commandFailed(tail(of: result)) }
    }

    private func tail(of result: ProcessResult) -> String {
        String(result.stderr.suffix(Self.errorTailLength))
    }
}
