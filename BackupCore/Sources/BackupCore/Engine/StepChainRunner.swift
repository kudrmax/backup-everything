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

/// Walks a source with a manual step through its steps. One call is one transition; the result accumulates in pending.
public struct StepChainRunner: Sendable {
    private let chainsRoot: URL
    private let inbox: ManualExportInbox
    private let runner: any ProcessRunner
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
        self.runner = runner
        self.time = time
        self.trash = { url in try FolderRemoval().trash(url, using: trash) }
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
            case .device:
                guard let path = source.devicePath(at: next.stepIndex), exists(path) else { return .stay }
            case .folder, .command:
                try folders.prepare()
                let process = StepProcessRecord(folders: folders)
                process.stopLeftover()
                try clearUnfinishedAttempt(of: next, in: folders)
                progress(.collecting(sourceId: source.id))
                progress(.step(sourceId: source.id, index: next.stepIndex, count: steps.count))
                let before = contents(of: folders.output)
                do {
                    _ = try await StepExecutor(runner: process.recording(runner)).run(step.kind, in: folders) { [progress] text in
                        progress(.status(sourceId: source.id, text: text))
                    }
                } catch {
                    for added in contents(of: folders.output).subtracting(before) {
                        try trash(folders.output.appendingPathComponent(added))
                    }
                    if let device = unpluggedDevice(before: next.stepIndex, in: source) {
                        next.stepIndex = device
                        next.stepId = steps[device].id
                        next.stepEnteredAt = time.now
                        next.outputAtStepEntry = contents(of: folders.output).sorted()
                        return .moved(next)
                    }
                    throw error
                }
            }
        } catch {
            next.failure = error.localizedDescription
            return .failed(next)
        }
        next.stepIndex += 1
        next.stepId = next.stepIndex < steps.count ? steps[next.stepIndex].id : nil
        next.stepEnteredAt = time.now
        next.outputAtStepEntry = contents(of: folders.output).sorted()
        return .moved(next)
    }

    public func awaitedFiles(_ source: Source, chain: ChainState?, lastPickup: Date?) -> InboxScan? {
        currentStepScan(source, chain: chain, lastPickup: lastPickup, now: time.now)
    }

    /// The current step is to connect a device, and it is not there.
    public func awaitsDevice(_ source: Source, chain: ChainState?) -> Bool {
        let index = chain?.stepIndex ?? 0
        guard index < source.steps.count, case .device = source.steps[index].kind else { return false }
        return source.devicePath(at: index).map { !exists($0) } ?? true
    }

    public func sourceIds() -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: chainsRoot.path)) ?? []
        return names.compactMap(UUID.init(uuidString:))
    }

    public func discard(sourceId: UUID) throws {
        let fileManager = FileManager.default
        let folders = folders(sourceId)
        StepProcessRecord(folders: folders).stopLeftover()
        for directory in [folders.input, folders.output] {
            for item in (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                try trash(item)
            }
        }
        if fileManager.fileExists(atPath: folders.root.path) {
            try FolderRemoval().remove(folders.root.path)
        }
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: Paths.url(path).path)
    }

    /// The step was interrupted (the app quit or crashed) and runs again: what its earlier attempt added goes to the Trash.
    private func clearUnfinishedAttempt(of chain: ChainState, in folders: WorkFolders) throws {
        guard let atEntry = chain.outputAtStepEntry else { return }
        for leftover in contents(of: folders.output).subtracting(atEntry) {
            try trash(folders.output.appendingPathComponent(leftover))
        }
    }

    private func contents(of directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    /// A step after the device failed and the device is gone: it was disconnected mid-copy. This is waiting, not an error.
    private func unpluggedDevice(before index: Int, in source: Source) -> Int? {
        guard let device = source.steps[..<index].lastIndex(where: { if case .device = $0.kind { true } else { false } }),
              let path = source.devicePath(at: device), !exists(path) else { return nil }
        return device
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

    /// The run may have been interrupted right after moving the result to pending: such a package is already this run's finished result.
    private func isProduct(_ package: PendingPackage, of chain: ChainState) -> Bool {
        package.collectedAt.addingTimeInterval(1) > chain.startedAt
    }

    /// Pick up all files or none: on an error the ones already moved are put back.
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
