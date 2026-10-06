import Foundation

public enum OverallStatus: Int, Sendable, Comparable {
    case ok
    case attention
    case error

    public static func < (lhs: OverallStatus, rhs: OverallStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Destinations of a source whose newest copy is past their rhythm or missing (5.5).
public struct OutdatedCopies: Sendable, Equatable {
    public let destinationIds: [UUID]
    /// Another destination of the source holds a fresh copy.
    public let freshElsewhere: Bool
    /// No destination of the source holds any copy at all.
    public let noCopyAnywhere: Bool

    public init(destinationIds: [UUID], freshElsewhere: Bool, noCopyAnywhere: Bool) {
        self.destinationIds = destinationIds
        self.freshElsewhere = freshElsewhere
        self.noCopyAnywhere = noCopyAnywhere
    }
}

public enum AttentionItem: Sendable, Equatable {
    case runFailed(sourceId: UUID, message: String)
    case copiesOutdated(sourceId: UUID, OutdatedCopies)
    /// The copy was delivered, but something after it went wrong and stays so: old copies were not cleaned up.
    case deliveryWarning(sourceId: UUID, message: String)
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
    /// Sources with a copy within its rhythm on every destination: the only sources that may look fine.
    public let fresh: Set<UUID>
    /// Sources a fresh copy is expected of: enabled, with destinations, that have run or delivered a copy.
    public let expected: Set<UUID>

    public init(items: [AttentionItem], fresh: Set<UUID> = [], expected: Set<UUID> = []) {
        self.items = items
        self.fresh = fresh
        self.expected = expected
    }

    /// Fine only when every source a copy is expected of has proved a fresh one, not merely when no problem is known.
    public var overall: OverallStatus {
        let unproven: OverallStatus = expected.isSubset(of: fresh) ? .ok : .attention
        return max(items.map(\.severity).max() ?? .ok, unproven)
    }

    /// The report without the sources in `ignored`: what is running or queued is judged when it is done.
    public func excludingSources(_ ignored: Set<UUID>) -> StatusReport {
        StatusReport(
            items: items.filter { item in item.sourceId.map { !ignored.contains($0) } ?? true },
            fresh: fresh.subtracting(ignored),
            expected: expected.subtracting(ignored)
        )
    }
}

extension AttentionItem {
    public var sourceId: UUID? {
        switch self {
        case let .runFailed(sourceId, _), let .copiesOutdated(sourceId, _), let .deliveryWarning(sourceId, _),
             let .severelyOverdue(sourceId), let .manualExportDue(sourceId), let .waitingForFile(sourceId),
             let .deviceDue(sourceId), let .waitingForDevice(sourceId), let .filesAwaitingPickup(sourceId, _, _, _),
             let .noDestinations(sourceId):
            sourceId
        case .destinationUnavailable, .connectDestination:
            nil
        }
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
        var fresh: Set<UUID> = []
        var expected: Set<UUID> = []
        for source in config.sources where source.enabled {
            let sourceState = state.sourceState(source.id)
            let destinations = config.destinations(of: source)
            if destinations.isEmpty {
                items.append(.noDestinations(sourceId: source.id))
                continue
            }
            let copies = destinations.map { state.deliveredCopyDate(sourceId: source.id, destinationId: $0.id) }
            let newestCopy = copies.compactMap { $0 }.max()
            if sourceState.lastRun != nil || newestCopy != nil {
                expected.insert(source.id)
                let outdated = zip(destinations, copies)
                    .filter { !planner.isCopyFresh(source, on: $0, copiedAt: $1, state: state, now: now) }
                    .map(\.0.id)
                if outdated.isEmpty {
                    fresh.insert(source.id)
                } else {
                    items.append(.copiesOutdated(sourceId: source.id, OutdatedCopies(
                        destinationIds: outdated,
                        freshElsewhere: outdated.count < destinations.count,
                        noCopyAnywhere: newestCopy == nil
                    )))
                }
            }
            let scan = inboxScans[source.id]
            let heldBack = scan.flatMap { $0.downloadInProgress && !$0.files.isEmpty ? $0 : nil }
            if let message = (heldBack == nil ? sourceState.chain?.failure : nil) ?? sourceState.lastError {
                items.append(.runFailed(sourceId: source.id, message: message))
            }
            let warnings = state.deliveryWarnings(of: source)
            if !warnings.isEmpty {
                items.append(.deliveryWarning(sourceId: source.id, message: warnings.joined(separator: " ")))
            }
            if planner.isSeverelyOverdue(source, on: destinations, state: state, now: now) {
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
        return StatusReport(items: items, fresh: fresh, expected: expected)
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
