import BackupCore
import Foundation

/// A destination of a source that holds no copy within its rhythm, and why.
struct CopyGap: Equatable {
    let destinationName: String
    let reason: String
}

/// The destinations of a source without a fresh copy, as the overview and the menu tell about them (5.5).
struct CopyShortfall: Equatable {
    let gaps: [CopyGap]
    let freshElsewhere: Bool
    let noCopyAnywhere: Bool

    var note: String {
        let reasons = Set(gaps.map(\.reason))
        guard reasons.count == 1, let reason = reasons.first else { return headline }
        return "\(headline) · \(reason)"
    }

    var text: String {
        let title = headline.prefix(1).uppercased() + String(headline.dropFirst())
        let lines = gaps.map { "“\($0.destinationName)”: \($0.reason)" }
        return ([title] + lines).joined(separator: "\n")
    }

    private var headline: String {
        if noCopyAnywhere { return "no copy anywhere" }
        if !freshElsewhere { return "no fresh copy anywhere" }
        return "no fresh copy on " + gaps.map { "“\($0.destinationName)”" }.joined(separator: ", ")
    }
}

/// Why the newest copy of a source on a destination is not fresh: what is wrong with the destination, else what is known
/// about the copy itself.
struct CopyGaps {
    let config: Config
    let state: AppState
    let report: StatusReport
    var unavailable: Set<UUID> = []
    var disks: [UUID: DiskCheck] = [:]
    var missingFolders: [UUID: MissingFolder] = [:]
    var runs: [RunRecord] = []
    var now = Date()

    func shortfall(of sourceId: UUID, _ outdated: OutdatedCopies) -> CopyShortfall {
        CopyShortfall(
            gaps: outdated.destinationIds.compactMap { gap(of: sourceId, at: $0) },
            freshElsewhere: outdated.freshElsewhere,
            noCopyAnywhere: outdated.noCopyAnywhere
        )
    }

    func gap(of sourceId: UUID, at destinationId: UUID) -> CopyGap? {
        guard let destination = config.destination(destinationId) else { return nil }
        return CopyGap(destinationName: destination.name, reason: reason(sourceId: sourceId, destination: destination))
    }

    private func reason(sourceId: UUID, destination: Destination) -> String {
        let condition = DestinationCondition.of(
            destination.id,
            report: report,
            unavailable: unavailable,
            disk: disks[destination.id],
            missingFolder: missingFolders[destination.id]
        )
        if let problem = condition.problem { return problem }
        let owed = state.hasDebt(sourceId: sourceId, destinationId: destination.id)
        if owed, case let .failed(message)? = lastOutcome(of: sourceId, at: destination.id) {
            return "couldn’t write: \(Texts.errorHeadline(message))"
        }
        if condition == .offline {
            return destination.expectedEvery == .always ? "unavailable" : "waiting for connection"
        }
        if owed { return "waiting to be written" }
        guard let copiedAt = state.deliveredCopyDate(sourceId: sourceId, destinationId: destination.id) else { return "no copy yet" }
        return "last copy \(Texts.relative(copiedAt, to: now))"
    }

    private func lastOutcome(of sourceId: UUID, at destinationId: UUID) -> DeliveryOutcome? {
        for run in runs where run.sourceId == sourceId {
            if let delivery = run.deliveries.first(where: { $0.destinationId == destinationId }) { return delivery.outcome }
        }
        return nil
    }
}
