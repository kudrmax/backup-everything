import Foundation

public enum ChainTransition: Sendable, Equatable {
    case stay
    case moved(ChainState?)
    case failed(ChainState)
    case completed(PendingPackage)
}

public struct ChainPermissions: Sendable, Equatable {
    public var mayStart: Bool
    public var mayRetry: Bool

    public init(mayStart: Bool, mayRetry: Bool) {
        self.mayStart = mayStart
        self.mayRetry = mayRetry
    }
}

public struct StepChainRunner: Sendable {
    private struct Folders {
        let root: URL
        var input: URL { root.appendingPathComponent("input", isDirectory: true) }
        var output: URL { root.appendingPathComponent("output", isDirectory: true) }
        var scratch: URL { root.appendingPathComponent("scratch", isDirectory: true) }
        var all: [URL] { [input, output, scratch] }
    }

    private let chainsRoot: URL
    private let inbox: ManualExportInbox
    private let shell: ShellCommand
    private let time: any TimeSource
    private let trash: ManualExportInbox.Trash
    private let progress: ProgressHandler

    public init(
        chainsRoot: URL,
        inbox: ManualExportInbox,
        runner: any ProcessRunner,
        time: any TimeSource,
        trash: @escaping ManualExportInbox.Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        progress: @escaping ProgressHandler = { _ in }
    ) {
        self.chainsRoot = chainsRoot
        self.inbox = inbox
        self.shell = ShellCommand(runner: runner)
        self.time = time
        self.trash = trash
        self.progress = progress
    }

    public func advance(_ source: Source, chain: ChainState?, lastPickup: Date?, permissions: ChainPermissions) async -> ChainTransition {
        let steps = source.steps
        guard !steps.isEmpty else { return .stay }
        let now = time.now
        if let chain, isOutOfPlace(chain, in: steps) {
            try? discard(sourceId: source.id)
            return .moved(nil)
        }
        if chain?.failure != nil, !permissions.mayRetry { return .stay }
        guard chain != nil || permissions.mayStart else { return .stay }

        var next = chain ?? ChainState(stepIndex: 0, stepId: steps[0].id, startedAt: now, stepEnteredAt: now)
        next.failure = nil
        let folders = folders(source.id)
        do {
            if chain == nil { try discard(sourceId: source.id) }
            guard next.stepIndex < steps.count else {
                return .completed(try assemble(source.id, chain: next, folders: folders, at: now))
            }
            switch steps[next.stepIndex].kind {
            case let .manual(_, _, _, includeInCopy):
                guard let scan = currentStepScan(source, chain: chain, lastPickup: lastPickup, now: now), scan.isReady else { return .stay }
                try prepare(folders)
                try take(scan.files, into: includeInCopy ? folders.output : folders.input)
            case let .command(command, timeoutSeconds):
                try prepare(folders)
                progress(.collecting(sourceId: source.id))
                progress(.step(sourceId: source.id, index: next.stepIndex, count: steps.count))
                _ = try await shell.run(
                    command,
                    timeoutSeconds: timeoutSeconds,
                    environment: [
                        "BACKUP_INPUT_DIR": folders.input.path,
                        "BACKUP_OUTPUT_DIR": folders.output.path,
                        "BACKUP_SCRATCH_DIR": folders.scratch.path,
                    ],
                    status: { [progress] text in progress(.status(sourceId: source.id, text: text)) }
                )
            }
        } catch {
            next.failure = error.localizedDescription
            return .failed(next)
        }
        next.stepIndex += 1
        next.stepId = next.stepIndex < steps.count ? steps[next.stepIndex].id : nil
        next.stepEnteredAt = time.now
        return .moved(next)
    }

    public func awaitedFiles(_ source: Source, chain: ChainState?, lastPickup: Date?) -> InboxScan? {
        let steps = source.steps
        guard !steps.isEmpty else { return nil }
        return currentStepScan(source, chain: chain, lastPickup: lastPickup, now: time.now)
    }

    public func sourceIds() -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: chainsRoot.path)) ?? []
        return names.compactMap(UUID.init(uuidString:))
    }

    public func discard(sourceId: UUID) throws {
        let fileManager = FileManager.default
        let folders = folders(sourceId)
        for directory in [folders.input, folders.output] {
            for item in (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                try trash(item)
            }
        }
        if fileManager.fileExists(atPath: folders.root.path) {
            try fileManager.removeItem(at: folders.root)
        }
    }

    private func isOutOfPlace(_ chain: ChainState, in steps: [SourceStep]) -> Bool {
        guard chain.stepIndex < steps.count else { return chain.stepIndex > steps.count || chain.stepId != nil }
        return steps[chain.stepIndex].id != chain.stepId
    }

    private func currentStepScan(_ source: Source, chain: ChainState?, lastPickup: Date?, now: Date) -> InboxScan? {
        let steps = source.steps
        let index = chain?.stepIndex ?? 0
        guard index < steps.count, case let .manual(_, watchPath, filePattern, _) = steps[index].kind else { return nil }
        let since = chain.flatMap { $0.stepIndex > 0 ? $0.stepEnteredAt : nil } ?? lastPickup ?? source.createdAt
        return inbox.scan(watchPath: watchPath, filePattern: filePattern, since: since, now: now)
    }

    private func assemble(_ sourceId: UUID, chain: ChainState, folders: Folders, at date: Date) throws -> PendingPackage {
        let produced = (try? FileManager.default.contentsOfDirectory(atPath: folders.output.path)) ?? []
        if produced.isEmpty, let stored = inbox.pendingPackage(for: sourceId), isProduct(stored, of: chain) {
            try? discard(sourceId: sourceId)
            return stored
        }
        guard !produced.isEmpty else { throw SourceError.emptyResult }
        let package = try inbox.adopt(sourceId: sourceId, directory: folders.output, at: date)
        try? discard(sourceId: sourceId)
        return package
    }

    /// Сборку могли прервать сразу после переноса результата в pending: такой пакет — уже готовый результат этой цепочки.
    private func isProduct(_ package: PendingPackage, of chain: ChainState) -> Bool {
        package.collectedAt.addingTimeInterval(1) > chain.startedAt
    }

    private func prepare(_ folders: Folders) throws {
        for directory in folders.all {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func take(_ files: [URL], into directory: URL) throws {
        let fileManager = FileManager.default
        var moved: [(original: URL, taken: URL)] = []
        do {
            for file in files {
                let taken = directory.appendingPathComponent(file.lastPathComponent)
                try fileManager.moveItem(at: file, to: taken)
                moved.append((file, taken))
            }
        } catch {
            for item in moved.reversed() {
                try? fileManager.moveItem(at: item.taken, to: item.original)
            }
            throw error
        }
    }

    private func folders(_ sourceId: UUID) -> Folders {
        Folders(root: chainsRoot.appendingPathComponent(sourceId.uuidString, isDirectory: true))
    }
}
