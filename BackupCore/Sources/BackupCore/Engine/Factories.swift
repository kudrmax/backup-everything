import Foundation

public protocol SourceProviderFactory: Sendable {
    func provider(for source: Source) -> any SourceProvider
}

public protocol DestinationStoreFactory: Sendable {
    func store(for destination: Destination) -> any DestinationStore
}

public struct DefaultSourceProviderFactory: SourceProviderFactory {
    private let runner: any ProcessRunner
    private let stagingRoot: URL
    private let inbox: ManualExportInbox
    private let quit: any QuitSignal
    private let progress: ProgressHandler

    public init(
        runner: any ProcessRunner,
        stagingRoot: URL,
        inbox: ManualExportInbox,
        quit: any QuitSignal = ProcessGroups.shared,
        progress: @escaping ProgressHandler = { _ in }
    ) {
        self.runner = runner
        self.stagingRoot = stagingRoot
        self.inbox = inbox
        self.quit = quit
        self.progress = progress
    }

    public func provider(for source: Source) -> any SourceProvider {
        if source.needsHuman {
            return PendingSource(sourceId: source.id, trashAfterDelivery: source.trashesPickedUpFiles, inbox: inbox, quit: quit)
        }
        if let folder = source.singleFolder {
            return FolderSource(path: folder.path, excludes: folder.excludes)
        }
        return StepsSource(sourceId: source.id, steps: source.steps, stagingRoot: stagingRoot, runner: runner, progress: progress)
    }
}

public struct DefaultDestinationStoreFactory: DestinationStoreFactory {
    private let runner: any ProcessRunner
    private let rclone: RcloneLocator
    private let naming: SnapshotNaming

    public init(runner: any ProcessRunner, rclone: RcloneLocator, naming: SnapshotNaming) {
        self.runner = runner
        self.rclone = rclone
        self.naming = naming
    }

    public func store(for destination: Destination) -> any DestinationStore {
        switch destination.kind {
        case let .localFolder(path):
            LocalFolderDestination(root: Paths.url(path), naming: naming)
        case let .rclone(remote, path):
            RcloneDestination(executable: rclone.find(), remote: remote, path: path, runner: runner, naming: naming)
        }
    }
}
