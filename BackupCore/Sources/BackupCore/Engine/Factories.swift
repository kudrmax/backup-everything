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

    public init(runner: any ProcessRunner, stagingRoot: URL, inbox: ManualExportInbox) {
        self.runner = runner
        self.stagingRoot = stagingRoot
        self.inbox = inbox
    }

    public func provider(for source: Source) -> any SourceProvider {
        switch source.kind {
        case let .folder(path, excludes), let .device(path, excludes):
            FolderSource(path: path, excludes: excludes)
        case let .command(command, timeoutSeconds):
            CommandSource(command: command, timeoutSeconds: timeoutSeconds, stagingRoot: stagingRoot, runner: runner)
        case let .manualExport(_, _, _, removeOriginal):
            ManualExportSource(sourceId: source.id, removeOriginal: removeOriginal, inbox: inbox)
        case .steps:
            ManualExportSource(sourceId: source.id, removeOriginal: true, inbox: inbox)
        }
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
