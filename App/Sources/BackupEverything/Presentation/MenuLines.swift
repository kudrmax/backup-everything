import BackupCore
import Foundation

struct MenuLine: Equatable, Identifiable {
    enum Subject: Equatable {
        case source(Source)
        case destination(Destination)
    }

    let subject: Subject
    let severity: OverallStatus
    let text: String
    let canPickUp: Bool

    var id: UUID {
        switch subject {
        case let .source(source): source.id
        case let .destination(destination): destination.id
        }
    }

    var name: String {
        switch subject {
        case let .source(source): source.name
        case let .destination(destination): destination.name
        }
    }
}

enum MenuLines {
    static func of(config: Config, state: AppState, report: StatusReport, unavailable: Set<UUID>) -> [MenuLine] {
        let sources = config.sources.compactMap { source -> MenuLine? in
            let status = SourceStatus.of(source, report: report, lastRun: nil)
            guard source.enabled, status.severity != .ok, let note = status.note else { return nil }
            let text = ChainPosition.note(note, of: source, chain: state.sourceState(source.id).chain, status: status) ?? note
            return MenuLine(subject: .source(source), severity: status.severity, text: text, canPickUp: status.offersPickUp)
        }
        let destinations = config.destinations.compactMap { destination -> MenuLine? in
            let condition = DestinationCondition.of(destination.id, report: report, unavailable: unavailable)
            return condition.problem.map {
                MenuLine(subject: .destination(destination), severity: .attention, text: $0, canPickUp: false)
            }
        }
        let lines = sources + destinations
        return lines.filter { $0.severity == .error } + lines.filter { $0.severity != .error }
    }
}
