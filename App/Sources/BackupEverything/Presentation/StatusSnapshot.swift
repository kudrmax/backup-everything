import BackupCore
import Foundation

/// Everything the app says about how the backups stand, built from one check: the row marks, the destination icons, the
/// headline, the menu lines, “All good” and the menu bar icon all come from here, so they never disagree. Before the first
/// check nothing is known, so nothing looks fine. What is running or queued is judged when it is done: its old problems
/// neither show nor count meanwhile, but its copies keep the state the check proved, never better.
struct StatusSnapshot {
    let config: Config
    let state: AppState
    /// The last check; `nil` until the first one.
    let checked: StatusReport?
    let running: Set<UUID>
    var unavailable: Set<UUID> = []
    var disks: [UUID: DiskCheck] = [:]
    var missingFolders: [UUID: MissingFolder] = [:]
    var runs: [RunRecord] = []
    var now = Date()

    var isChecking: Bool { checked == nil }

    /// The check without the problems of what is running or queued.
    var live: StatusReport {
        LiveReport.of(checked ?? StatusReport(items: []), running: running)
    }

    var gaps: CopyGaps {
        CopyGaps(config: config, state: state, report: live, unavailable: unavailable, disks: disks, missingFolders: missingFolders, runs: runs, now: now)
    }

    func status(of source: Source, lastBackup: Date?) -> SourceStatus {
        SourceStatus.of(source, report: live, lastBackup: lastBackup, gaps: gaps)
    }

    /// A destination used by no enabled source holds no backup anyone waits for: what is wrong with it is shown in its
    /// settings, not counted in the backup health.
    func isUsed(_ destination: Destination) -> Bool {
        config.sources.contains { $0.enabled && $0.destinationIds.contains(destination.id) }
    }

    func condition(of destination: Destination) -> DestinationCondition {
        DestinationCondition.of(
            destination.id, report: live, unavailable: unavailable, disk: disks[destination.id], missingFolder: missingFolders[destination.id]
        )
    }

    var menuLines: [MenuLine] {
        let gaps = gaps
        let sources = config.sources.compactMap { source -> MenuLine? in
            let status = SourceStatus.of(source, report: live, lastBackup: nil, gaps: gaps)
            guard source.enabled, status.severity != .ok, let note = status.note else { return nil }
            let text = ChainPosition.note(note, of: source, chain: state.sourceState(source.id).chain, status: status) ?? note
            return MenuLine(subject: .source(source), severity: status.severity, text: text, canPickUp: status.offersPickUp)
        }
        let destinations = config.destinations.filter(isUsed).compactMap { destination -> MenuLine? in
            condition(of: destination).problem.map {
                MenuLine(subject: .destination(destination), severity: .attention, text: $0, canPickUp: false)
            }
        }
        let lines = sources + destinations
        return lines.filter { $0.severity == .error } + lines.filter { $0.severity != .error }
    }

    /// `nil` until the first check. Fine only when the check proved a fresh copy of every source it expects one of and
    /// there is not a single line to show.
    var overall: OverallStatus? {
        guard !isChecking else { return nil }
        return max(live.overall, menuLines.map(\.severity).max() ?? .ok)
    }

    var isAllGood: Bool { overall == .ok }

    func headline(isWorking: Bool) -> String {
        guard let overall else { return "Checking…" }
        let errors = menuLines.filter { $0.severity == .error }.count
        if errors > 0 { return Texts.errors(errors) }
        guard overall == .ok else { return "Needs your action" }
        return isWorking ? "Backing up" : "All good"
    }

    /// What the icon of a destination in the row of a source shows. A green check only where the check proved a copy within
    /// the destination's rhythm; a source being backed up keeps what the check proved.
    func delivery(of source: Source, to destination: Destination) -> DeliveryState {
        if state.hasDebt(sourceId: source.id, destinationId: destination.id) {
            if case .failed? = lastOutcome(of: source.id, at: destination.id) { return .failed }
            return .waiting
        }
        let hasCopy = state.deliveredCopyDate(sourceId: source.id, destinationId: destination.id) != nil
        guard let checked else { return .unconfirmed }
        guard checked.expected.contains(source.id) else { return hasCopy ? .unconfirmed : .none }
        let outdated = checked.items.contains { item in
            guard case let .copiesOutdated(sourceId, copies) = item else { return false }
            return sourceId == source.id && copies.destinationIds.contains(destination.id)
        }
        guard outdated else { return .delivered }
        return hasCopy ? .outdated : .none
    }

    private func lastOutcome(of sourceId: UUID, at destinationId: UUID) -> DeliveryOutcome? {
        for run in runs where run.sourceId == sourceId {
            if let delivery = run.deliveries.first(where: { $0.destinationId == destinationId }) { return delivery.outcome }
        }
        return nil
    }
}
