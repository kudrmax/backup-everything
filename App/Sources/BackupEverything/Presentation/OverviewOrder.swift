import BackupCore
import Foundation

/// Порядок источников в обзоре.
enum OverviewOrder: String, CaseIterable, Identifiable {
    case manual
    case nextBackup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "Как в настройках"
        case .nextBackup: "По следующему бэкапу"
        }
    }

    /// Ближайший бэкап выше; без расписания и выключенные — внизу, в порядке настроек.
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
