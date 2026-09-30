import Foundation

public struct CommandSource: SourceProvider {
    private static let shell = URL(fileURLWithPath: "/bin/zsh")
    private static let outputTailLength = 4096

    private let command: String
    private let timeoutSeconds: Int
    private let stagingRoot: URL
    private let runner: any ProcessRunner

    public init(command: String, timeoutSeconds: Int, stagingRoot: URL, runner: any ProcessRunner) {
        self.command = command
        self.timeoutSeconds = timeoutSeconds
        self.stagingRoot = stagingRoot
        self.runner = runner
    }

    public func collect(at date: Date, status: @escaping StatusHandler) async throws -> Payload {
        let fileManager = FileManager.default
        let session = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let output = session.appendingPathComponent("output", isDirectory: true)
        let scratch = session.appendingPathComponent("scratch", isDirectory: true)
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        do {
            let result = try await runner.run(
                executable: Self.shell,
                arguments: ["-lc", command],
                environment: ["BACKUP_OUTPUT_DIR": output.path, "BACKUP_SCRATCH_DIR": scratch.path],
                timeout: TimeInterval(timeoutSeconds),
                onOutput: status
            )
            let tail = Self.tail(of: result)
            if result.timedOut {
                throw SourceError.commandTimedOut(seconds: timeoutSeconds, output: tail)
            }
            guard result.exitCode == 0 else {
                throw SourceError.commandFailed(exitCode: result.exitCode, output: tail)
            }
            return Payload(root: output, collectedAt: date, details: tail.isEmpty ? nil : tail)
        } catch {
            try? fileManager.removeItem(at: session)
            throw error
        }
    }

    public func finish(_ payload: Payload, deliveredEverywhere: Bool) {
        try? FileManager.default.removeItem(at: payload.root.deletingLastPathComponent())
    }

    private static func tail(of result: ProcessResult) -> String {
        let combined = [result.stdout, result.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return String(combined.suffix(outputTailLength))
    }
}
