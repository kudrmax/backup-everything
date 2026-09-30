import Foundation

public struct CommandSource: SourceProvider {
    private let command: String
    private let timeoutSeconds: Int
    private let stagingRoot: URL
    private let shell: ShellCommand

    public init(command: String, timeoutSeconds: Int, stagingRoot: URL, runner: any ProcessRunner) {
        self.command = command
        self.timeoutSeconds = timeoutSeconds
        self.stagingRoot = stagingRoot
        self.shell = ShellCommand(runner: runner)
    }

    public func collect(at date: Date, status: @escaping StatusHandler) async throws -> Payload {
        let fileManager = FileManager.default
        let session = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let output = session.appendingPathComponent("output", isDirectory: true)
        let scratch = session.appendingPathComponent("scratch", isDirectory: true)
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        do {
            let tail = try await shell.run(
                command,
                timeoutSeconds: timeoutSeconds,
                environment: ["BACKUP_OUTPUT_DIR": output.path, "BACKUP_SCRATCH_DIR": scratch.path],
                status: status
            )
            return Payload(root: output, collectedAt: date, details: tail.isEmpty ? nil : tail)
        } catch {
            try? fileManager.removeItem(at: session)
            throw error
        }
    }

    public func finish(_ payload: Payload, deliveredEverywhere: Bool) {
        try? FileManager.default.removeItem(at: payload.root.deletingLastPathComponent())
    }
}
