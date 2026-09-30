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
    public var mayConfirm: Bool
    public var start: RunStart

    public init(mayStart: Bool, mayRetry: Bool, mayConfirm: Bool = false, start: RunStart = .schedule) {
        self.mayStart = mayStart
        self.mayRetry = mayRetry
        self.mayConfirm = mayConfirm
        self.start = start
    }
}

/// Проводит по шагам источник, в котором есть шаг человека. Один вызов — один переход; результат копится в pending.
public struct StepChainRunner: Sendable {
    private let chainsRoot: URL
    private let inbox: ManualExportInbox
    private let executor: StepExecutor
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
        self.executor = StepExecutor(runner: runner)
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

        var next = chain ?? ChainState(stepIndex: 0, stepId: steps[0].id, startedAt: now, stepEnteredAt: now, startedBy: permissions.start)
        next.failure = nil
        next.retryAfter = nil
        let folders = folders(source.id)
        do {
            if chain == nil { try discard(sourceId: source.id) }
            guard next.stepIndex < steps.count else {
                return .completed(try assemble(source.id, chain: next, folders: folders, at: now))
            }
            let step = steps[next.stepIndex]
            switch step.kind {
            case let .file(_, _, _, fileMode, includeInCopy, removeOriginal):
                guard let scan = currentStepScan(source, chain: chain, lastPickup: lastPickup, now: now), scan.isReady else { return .stay }
                if fileMode == .multiple, !permissions.mayConfirm { return .stay }
                try folders.prepare()
                do {
                    try take(scan.files, into: includeInCopy ? folders.output : folders.input, keepOriginals: !removeOriginal)
                } catch {
                    throw SourceError.pickupFailed(error.localizedDescription)
                }
            case let .device(_, path):
                guard FileManager.default.fileExists(atPath: Paths.url(path).path) else { return .stay }
            case .folder, .command:
                try folders.prepare()
                progress(.collecting(sourceId: source.id))
                progress(.step(sourceId: source.id, index: next.stepIndex, count: steps.count))
                _ = try await executor.run(step.kind, in: folders) { [progress] text in
                    progress(.status(sourceId: source.id, text: text))
                }
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
        currentStepScan(source, chain: chain, lastPickup: lastPickup, now: time.now)
    }

    /// Текущий шаг — подключить устройство, а его нет.
    public func awaitsDevice(_ source: Source, chain: ChainState?) -> Bool {
        let index = chain?.stepIndex ?? 0
        guard index < source.steps.count, case let .device(_, path) = source.steps[index].kind else { return false }
        return !FileManager.default.fileExists(atPath: Paths.url(path).path)
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
        guard index < steps.count, case let .file(_, watchPath, filePattern, _, _, _) = steps[index].kind else { return nil }
        let since = chain.flatMap { $0.stepIndex > 0 ? $0.stepEnteredAt : nil } ?? lastPickup ?? source.createdAt
        return inbox.scan(watchPath: watchPath, filePattern: filePattern, since: since, now: now)
    }

    private func assemble(_ sourceId: UUID, chain: ChainState, folders: WorkFolders, at date: Date) throws -> PendingPackage {
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

    /// Сборку могли прервать сразу после переноса результата в pending: такой пакет — уже готовый результат этого запуска.
    private func isProduct(_ package: PendingPackage, of chain: ChainState) -> Bool {
        package.collectedAt.addingTimeInterval(1) > chain.startedAt
    }

    /// Забрать все файлы или ни одного: при ошибке уже перенесённые возвращаются на место.
    private func take(_ files: [URL], into directory: URL, keepOriginals: Bool) throws {
        let fileManager = FileManager.default
        var taken: [(original: URL, copy: URL)] = []
        do {
            for file in files {
                let target = directory.appendingPathComponent(file.lastPathComponent)
                if keepOriginals {
                    try fileManager.copyItem(at: file, to: target)
                } else {
                    try fileManager.moveItem(at: file, to: target)
                }
                taken.append((file, target))
            }
        } catch {
            for item in taken.reversed() {
                if keepOriginals {
                    try? fileManager.removeItem(at: item.copy)
                } else {
                    try? fileManager.moveItem(at: item.copy, to: item.original)
                }
            }
            throw error
        }
    }

    private func folders(_ sourceId: UUID) -> WorkFolders {
        WorkFolders(root: chainsRoot.appendingPathComponent(sourceId.uuidString, isDirectory: true))
    }
}
