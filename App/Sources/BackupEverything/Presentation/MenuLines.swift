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
    static func of(
        config: Config,
        state: AppState,
        report: StatusReport,
        unavailable: Set<UUID>,
        disks: [UUID: DiskCheck] = [:],
        missingFolders: [UUID: MissingFolder] = [:],
        runs: [RunRecord] = [],
        now: Date = Date()
    ) -> [MenuLine] {
        StatusSnapshot(
            config: config, state: state, checked: report, running: [],
            unavailable: unavailable, disks: disks, missingFolders: missingFolders, runs: runs, now: now
        ).menuLines
    }
}
