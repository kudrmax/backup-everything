import Foundation

/// A source made of automatic steps only: every run builds the copy from scratch in a temporary folder.
/// What a failed run leaves there and cannot delete is deleted with the whole `staging` at the next launch.
public struct StepsSource: SourceProvider {
    private let removal = FolderRemoval()
    private let sourceId: UUID
    private let steps: [SourceStep]
    private let stagingRoot: URL
    private let executor: StepExecutor
    private let progress: ProgressHandler

    public init(sourceId: UUID, steps: [SourceStep], stagingRoot: URL, runner: any ProcessRunner, progress: @escaping ProgressHandler = { _ in }) {
        self.sourceId = sourceId
        self.steps = steps
        self.stagingRoot = stagingRoot
        self.executor = StepExecutor(runner: runner)
        self.progress = progress
    }

    public func collect(at date: Date, status: @escaping StatusHandler) async throws -> Payload {
        let folders = WorkFolders(root: stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true))
        try folders.prepare()
        var details: String?
        do {
            for (index, step) in steps.enumerated() {
                if steps.count > 1 { progress(.step(sourceId: sourceId, index: index, count: steps.count)) }
                do {
                    details = try await executor.run(step.kind, in: folders, status: status) ?? details
                } catch {
                    throw steps.count > 1 ? SourceError.stepFailed(index: index, count: steps.count, name: step.name, reason: error.localizedDescription) : error
                }
            }
        } catch {
            try? removal.remove(folders.root.path)
            throw error
        }
        return Payload(root: folders.output, collectedAt: date, details: details.flatMap { $0.isEmpty ? nil : $0 })
    }

    public func finish(_ payload: Payload, deliveredEverywhere: Bool) throws {
        try removal.remove(payload.root.deletingLastPathComponent().path)
    }
}
