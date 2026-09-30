import Foundation

public struct ShellCommand: Sendable {
    private static let shell = URL(fileURLWithPath: "/bin/zsh")
    private static let outputTailLength = 4096

    private let runner: any ProcessRunner

    public init(runner: any ProcessRunner) {
        self.runner = runner
    }

    public func run(
        _ command: String,
        timeoutSeconds: Int,
        environment: [String: String],
        status: @escaping StatusHandler
    ) async throws -> String {
        let result = try await runner.run(
            executable: Self.shell,
            arguments: ["-lc", command],
            environment: environment,
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
        return tail
    }

    private static func tail(of result: ProcessResult) -> String {
        let combined = [result.stdout, result.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return String(combined.suffix(outputTailLength))
    }
}
