import BackupCore
import Foundation

/// The order of sources in the overview.
enum OverviewOrder: String, CaseIterable, Identifiable {
    case manual
    case nextBackup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "As in settings"
        case .nextBackup: "By next backup"
        }
    }

    /// The nearest backup first; unscheduled and disabled ones at the bottom, in settings order.
    func sorted(_ sources: [Source], nextDue: (Source) -> Date?) -> [Source] {
        guard self == .nextBackup else { return sources }
        return sources.enumerated()
            .map { (offset: $0.offset, source: $0.element, due: $0.element.enabled ? nextDue($0.element) : nil) }
            .sorted { first, second in
                switch (first.due, second.due) {
                case let (a?, b?) where a != b: a < b
                case (_?, nil): true
                case (nil, _?): false
                default: first.offset < second.offset
                }
            }
            .map(\.source)
    }
}
