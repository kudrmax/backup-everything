import Foundation

/// The command a step is running, written next to the run's folders. If the app dies with the command still running,
/// the next launch stops it before the step runs again in the same folders or the folders are deleted.
struct StepProcessRecord: Sendable {
    static let grace: TimeInterval = 2

    let file: URL

    init(folders: WorkFolders) {
        file = folders.root.appendingPathComponent("process.json")
    }

    /// Stops what the runs in the folders under `root` left running.
    static func stopLeftovers(under root: URL) {
        let runs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for run in runs {
            StepProcessRecord(folders: WorkFolders(root: run)).stopLeftover()
        }
    }

    func recording(_ runner: any ProcessRunner) -> any ProcessRunner {
        RecordingRunner(base: runner, record: self)
    }

    func stopLeftover() {
        guard let data = try? Data(contentsOf: file) else { return }
        if let identity = try? JSONDecoder().decode(ProcessIdentity.self, from: data) {
            identity.terminateGroup(grace: Self.grace)
        }
        forget()
    }

    func forget() {
        try? FileManager.default.removeItem(at: file)
    }

    fileprivate func remember(_ identity: ProcessIdentity) {
        try? JSONEncoder().encode(identity).write(to: file, options: .atomic)
    }
}

private struct RecordingRunner: ProcessRunner {
    let base: any ProcessRunner
    let record: StepProcessRecord

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        defer { record.forget() }
        return try await base.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout,
            onOutput: onOutput,
            onSpawn: { [record] in record.remember($0) }
        )
    }
}
