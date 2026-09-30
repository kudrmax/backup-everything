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
    case stepAwaitingFile(sourceId: UUID)
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
        connectedDevices: Set<UUID> = []
    ) -> StatusReport {
        var items: [AttentionItem] = []
        for source in config.sources where source.enabled {
            let sourceState = state.sourceState(source.id)
            if config.destinations(of: source).isEmpty {
                items.append(.noDestinations(sourceId: source.id))
                continue
            }
            let heldBack = source.isStepChain ? inboxScans[source.id].flatMap { $0.downloadInProgress && !$0.files.isEmpty ? $0 : nil } : nil
            if let message = (heldBack == nil ? sourceState.chain?.failure : nil) ?? sourceState.lastError {
                items.append(.runFailed(sourceId: source.id, message: message))
            }
            if planner.isSeverelyOverdue(source, state: sourceState, now: now) {
                items.append(.severelyOverdue(sourceId: source.id))
            }
            if source.isDevice {
                if !connectedDevices.contains(source.id) {
                    if planner.isDue(source, state: sourceState, now: now) {
                        items.append(.deviceDue(sourceId: source.id))
                    } else if sourceState.armedAt != nil {
                        items.append(.waitingForDevice(sourceId: source.id))
                    }
                }
                continue
            }
            if let heldBack {
                items.append(.filesAwaitingPickup(
                    sourceId: source.id,
                    fileCount: heldBack.files.count,
                    totalBytes: heldBack.totalBytes,
                    downloadInProgress: true
                ))
                continue
            }
            if source.isStepChain {
                items.append(contentsOf: chainItems(source, state: sourceState, now: now))
                continue
            }
            guard source.isManualExport else { continue }
            if let scan = inboxScans[source.id], !scan.files.isEmpty {
                items.append(.filesAwaitingPickup(
                    sourceId: source.id,
                    fileCount: scan.files.count,
                    totalBytes: scan.totalBytes,
                    downloadInProgress: scan.downloadInProgress
                ))
            } else if planner.isDue(source, state: sourceState, now: now) {
                items.append(.manualExportDue(sourceId: source.id))
            } else if sourceState.armedAt != nil {
                items.append(.waitingForFile(sourceId: source.id))
            }
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

    private func chainItems(_ source: Source, state: SourceState, now: Date) -> [AttentionItem] {
        let steps = source.steps
        guard let chain = state.chain else {
            if steps.first?.isManual == true && planner.isDue(source, state: state, now: now) {
                return [.manualExportDue(sourceId: source.id)]
            }
            return state.armedAt != nil ? [.waitingForFile(sourceId: source.id)] : []
        }
        guard chain.failure == nil, chain.stepIndex < steps.count, steps[chain.stepIndex].isManual else { return [] }
        return [.stepAwaitingFile(sourceId: source.id)]
    }
}
