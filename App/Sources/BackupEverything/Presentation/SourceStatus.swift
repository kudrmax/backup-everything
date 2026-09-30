import BackupCore
import Foundation

enum SourceStatus: Equatable {
    case disabled
    case failed(String)
    case overdue
    case noDestinations
    case filesFound(count: Int, bytes: Int64, downloading: Bool)
    case exportDue
    case neverRun
    case ok

    static func of(_ source: Source, report: StatusReport, lastRun: Date?) -> SourceStatus {
        guard source.enabled else { return .disabled }
        var found: [SourceStatus] = []
        for item in report.items {
            switch item {
            case let .runFailed(id, message) where id == source.id: found.append(.failed(message))
            case let .severelyOverdue(id) where id == source.id: found.append(.overdue)
            case let .noDestinations(id) where id == source.id: found.append(.noDestinations)
            case let .filesAwaitingPickup(id, count, bytes, downloading) where id == source.id:
                found.append(.filesFound(count: count, bytes: bytes, downloading: downloading))
            case let .manualExportDue(id) where id == source.id: found.append(.exportDue)
            default: break
            }
        }
        return found.min { $0.rank < $1.rank } ?? (lastRun == nil ? .neverRun : .ok)
    }

    var severity: OverallStatus {
        switch self {
        case .failed, .overdue: .error
        case .noDestinations, .filesFound, .exportDue: .attention
        case .disabled, .neverRun, .ok: .ok
        }
    }

    var text: String {
        switch self {
        case .disabled: "Выключен"
        case let .failed(message): "Ошибка: \(message)"
        case .overdue: "Бэкап сильно просрочен"
        case .noDestinations: "Не выбрано, куда бэкапить"
        case let .filesFound(count, bytes, downloading):
            "Найдено файлов: \(count), \(Texts.bytes(bytes))" + (downloading ? ". Идёт загрузка" : "")
        case .exportDue: "Пора сделать экспорт"
        case .neverRun: "Ещё не запускался"
        case .ok: "В порядке"
        }
    }

    var note: String? {
        switch self {
        case .ok, .neverRun: nil
        case .disabled: "выключен"
        case let .failed(message): Self.headline(of: message)
        case .overdue: "давно не было бэкапа"
        case .noDestinations: "не выбрано, куда бэкапить"
        case let .filesFound(count, bytes, downloading):
            "\(Texts.files(count)) · \(Texts.bytes(bytes))" + (downloading ? " · идёт загрузка" : "")
        case .exportDue: "пора сделать экспорт"
        }
    }

    private static func headline(of message: String) -> String {
        let cuts = [": ", ". "].compactMap { message.range(of: $0)?.lowerBound }
        guard let cut = cuts.min() else { return message }
        return String(message[..<cut])
    }

    private var rank: Int {
        switch self {
        case .failed: 0
        case .overdue: 1
        case .noDestinations: 2
        case .filesFound: 3
        case .exportDue: 4
        case .disabled, .neverRun, .ok: 5
        }
    }
}
