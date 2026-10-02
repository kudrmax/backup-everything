import Foundation

public enum OverallStatus: Int, Sendable, Comparable {
    case ok
    case attention
    case error

    public static func < (lhs: OverallStatus, rhs: OverallStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum AttentionItem: Sendable, Equatable {
    case runFailed(sourceId: UUID, message: String)
    case severelyOverdue(sourceId: UUID)
    case manualExportDue(sourceId: UUID)
    case filesAwaitingPickup(sourceId: UUID, fileCount: Int, totalBytes: Int64, downloadInProgress: Bool)
    case waitingForFile(sourceId: UUID)
    case deviceDue(sourceId: UUID)
    case waitingForDevice(sourceId: UUID)
    case noDestinations(sourceId: UUID)
    case destinationUnavailable(destinationId: UUID)
    case connectDestination(destinationId: UUID)

    public var severity: OverallStatus {
        switch self {
        case .runFailed, .severelyOverdue: .error
        case .waitingForFile, .waitingForDevice: .ok
        default: .attention
        }
    }
}

public struct StatusReport: Sendable, Equatable {
    public let items: [AttentionItem]

    public init(items: [AttentionItem]) {
        self.items = items
    }

    public var overall: OverallStatus {
        items.map(\.severity).max() ?? .ok
    }
}

public struct StatusReporter: Sendable {
    private let planner: SchedulePlanner

    public init(planner: SchedulePlanner) {
        self.planner = planner
    }

    public func report(
        config: Config,
        state: AppState,
        now: Date,
        unavailableDestinations: Set<UUID>,
        inboxScans: [UUID: InboxScan],
        missingDevices: Set<UUID> = []
    ) -> StatusReport {
        let state = state.pausingDisabledSources(of: config)
        var items: [AttentionItem] = []
        for source in config.sources where source.enabled {
            let sourceState = state.sourceState(source.id)
            if config.destinations(of: source).isEmpty {
                items.append(.noDestinations(sourceId: source.id))
                continue
            }
            let scan = inboxScans[source.id]
            let heldBack = scan.flatMap { $0.downloadInProgress && !$0.files.isEmpty ? $0 : nil }
            if let message = (heldBack == nil ? sourceState.chain?.failure : nil) ?? sourceState.lastError {
                items.append(.runFailed(sourceId: source.id, message: message))
            }
            if planner.isSeverelyOverdue(source, state: sourceState, now: now) {
                items.append(.severelyOverdue(sourceId: source.id))
            }
            guard source.needsHuman else { continue }
            if let heldBack {
                items.append(.filesAwaitingPickup(
                    sourceId: source.id,
                    fileCount: heldBack.files.count,
                    totalBytes: heldBack.totalBytes,
                    downloadInProgress: true
                ))
                continue
            }
            items.append(contentsOf: humanStepItems(
                source,
                state: sourceState,
                scan: scan,
                deviceMissing: missingDevices.contains(source.id),
                now: now
            ))
        }
        for destination in config.destinations where unavailableDestinations.contains(destination.id) {
            guard !state.debts(forDestination: destination.id).isEmpty else { continue }
            switch destination.expectedEvery {
            case .always:
                items.append(.destinationUnavailable(destinationId: destination.id))
            case .days:
                if let deadline = planner.connectDeadline(for: destination, state: state), deadline <= now {
                    items.append(.connectDestination(destinationId: destination.id))
                }
            }
        }
        return StatusReport(items: items)
    }

    /// What to show while a source waits for a manual step: “time to …” if the run was started by the schedule, and a calm “waiting for …” if by the button.
    private func humanStepItems(_ source: Source, state: SourceState, scan: InboxScan?, deviceMissing: Bool, now: Date) -> [AttentionItem] {
        let chain = state.chain
        guard chain != nil || planner.awaitsFile(source, state: state, now: now) else { return [] }
        let index = chain?.stepIndex ?? 0
        guard index < source.steps.count else { return [] }
        if chain?.failure != nil {
            guard case .file = source.steps[index].kind, let scan, !scan.files.isEmpty else { return [] }
            return [.filesAwaitingPickup(sourceId: source.id, fileCount: scan.files.count, totalBytes: scan.totalBytes, downloadInProgress: scan.downloadInProgress)]
        }
        let byButton = chain.map { $0.startedBy == .button } ?? !planner.dueDateReached(source, state: state, now: now)
        switch source.steps[index].kind {
        case .file:
            if let scan, !scan.files.isEmpty {
                return [.filesAwaitingPickup(
                    sourceId: source.id,
                    fileCount: scan.files.count,
                    totalBytes: scan.totalBytes,
                    downloadInProgress: scan.downloadInProgress
                )]
            }
            return [byButton ? .waitingForFile(sourceId: source.id) : .manualExportDue(sourceId: source.id)]
        case .device:
            guard deviceMissing else { return [] }
            return [byButton ? .waitingForDevice(sourceId: source.id) : .deviceDue(sourceId: source.id)]
        case .folder, .command:
            return []
        }
    }
}
