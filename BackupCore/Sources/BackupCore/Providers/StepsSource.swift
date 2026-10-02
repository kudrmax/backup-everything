import Foundation

/// A source made of automatic steps only: every run builds the copy from scratch in a temporary folder. A command may move
/// a person's originals into its output, so what a run made goes to the Trash unless a copy of it was delivered somewhere.
/// What a run leaves in `staging` and cannot clear is cleared at the next launch.
/// The running command is recorded next to the folder, so that the next launch stops it if the app dies first.
public struct StepsSource: SourceProvider {
    private let sourceId: UUID
    private let steps: [SourceStep]
    private let stagingRoot: URL
    private let runner: any ProcessRunner
    private let trash: ManualExportInbox.Trash
    private let progress: ProgressHandler

    public init(
        sourceId: UUID,
        steps: [SourceStep],
        stagingRoot: URL,
        runner: any ProcessRunner,
        trash: @escaping ManualExportInbox.Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        progress: @escaping ProgressHandler = { _ in }
    ) {
        self.sourceId = sourceId
        self.steps = steps
        self.stagingRoot = stagingRoot
        self.runner = runner
        self.trash = { url in try FolderRemoval().trash(url, using: trash) }
        self.progress = progress
    }

    public func collect(at date: Date, status: @escaping StatusHandler) async throws -> Payload {
        let folders = WorkFolders(root: stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true))
        try folders.prepare()
        let executor = StepExecutor(runner: StepProcessRecord(folders: folders).recording(runner))
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
            do {
                try folders.discard(using: trash)
            } catch let cleanup {
                throw SourceError.leftoversRemain(reason: error.localizedDescription, cleanup: cleanup.localizedDescription)
            }
            throw error
        }
        return Payload(root: folders.output, collectedAt: date, details: details.flatMap { $0.isEmpty ? nil : $0 })
    }

    public func finish(_ payload: Payload, delivered: PayloadDelivery) throws {
        let folders = WorkFolders(root: payload.root.deletingLastPathComponent())
        if delivered == .nowhere {
            try folders.discard(using: trash)
        } else {
            try FolderRemoval().remove(folders.root.path)
        }
    }
}
