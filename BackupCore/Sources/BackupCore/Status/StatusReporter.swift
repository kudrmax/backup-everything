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
    case noDestinations(sourceId: UUID)
    case destinationUnavailable(destinationId: UUID)
    case connectDestination(destinationId: UUID)

    public var severity: OverallStatus {
        switch self {
        case .runFailed, .severelyOverdue: .error
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
        inboxScans: [UUID: InboxScan]
    ) -> StatusReport {
        var items: [AttentionItem] = []
        for source in config.sources where source.enabled {
            let sourceState = state.sourceState(source.id)
            if config.destinations(of: source).isEmpty {
                items.append(.noDestinations(sourceId: source.id))
                continue
            }
            if let message = sourceState.chain?.failure ?? sourceState.lastError {
                items.append(.runFailed(sourceId: source.id, message: message))
            }
            if planner.isSeverelyOverdue(source, state: sourceState, now: now) {
                items.append(.severelyOverdue(sourceId: source.id))
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
            let waitsForHuman = steps.first?.isManual == true && planner.isDue(source, state: state, now: now)
            return waitsForHuman ? [.manualExportDue(sourceId: source.id)] : []
        }
        guard chain.failure == nil, chain.stepIndex < steps.count, steps[chain.stepIndex].isManual else { return [] }
        return [.stepAwaitingFile(sourceId: source.id)]
    }
}
