import Foundation

/// Runs automatic steps — folder and command — in the run's working folders.
struct StepExecutor: Sendable {
    private let shell: ShellCommand
    private let walker = PayloadWalker()
    private let copier = PayloadCopier()

    init(runner: any ProcessRunner) {
        shell = ShellCommand(runner: runner)
    }

    /// Returns the tail of the command output; nil for a folder.
    func run(_ kind: StepKind, in folders: WorkFolders, status: @escaping StatusHandler) async throws -> String? {
        switch kind {
        case let .folder(path, excludes):
            try copy(Payload(root: Paths.url(path), excludes: excludes, collectedAt: Date()), into: folders.output)
            return nil
        case let .command(command, timeoutSeconds):
            return try await shell.run(command, timeoutSeconds: timeoutSeconds, environment: folders.environment, status: status)
        case .file, .device:
            preconditionFailure("Manual steps are run by StepChainRunner")
        }
    }

    private func copy(_ payload: Payload, into directory: URL) throws {
        let listing = try walker.listing(of: payload)
        try copier.copy(listing, into: directory.path).check(in: directory.path)
    }
}
