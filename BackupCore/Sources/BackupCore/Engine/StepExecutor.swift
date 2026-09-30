import Foundation

/// Выполняет автоматические шаги — папку и команду — в рабочих папках запуска.
struct StepExecutor: Sendable {
    private let shell: ShellCommand
    private let walker = PayloadWalker()

    init(runner: any ProcessRunner) {
        shell = ShellCommand(runner: runner)
    }

    /// Возвращает хвост вывода команды, у папки — nil.
    func run(_ kind: StepKind, in folders: WorkFolders, status: @escaping StatusHandler) async throws -> String? {
        switch kind {
        case let .folder(path, excludes):
            try copy(Payload(root: Paths.url(path), excludes: excludes, collectedAt: Date()), into: folders.output)
            return nil
        case let .command(command, timeoutSeconds):
            return try await shell.run(command, timeoutSeconds: timeoutSeconds, environment: folders.environment, status: status)
        case .file, .device:
            preconditionFailure("Шаги человека выполняет StepChainRunner")
        }
    }

    private func copy(_ payload: Payload, into directory: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: payload.root.path) else {
            throw SourceError.pathMissing(payload.root.path)
        }
        guard walker.isDirectory(payload) else {
            try fileManager.copyItem(at: payload.root, to: directory.appendingPathComponent(payload.root.lastPathComponent))
            return
        }
        for entry in try walker.entries(of: payload) {
            let target = directory.appendingPathComponent(entry.relativePath)
            switch entry.kind {
            case .directory:
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            case .file, .symlink:
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: entry.url, to: target)
            }
        }
    }
}
