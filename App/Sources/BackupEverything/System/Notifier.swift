import BackupCore
import Foundation
import UserNotifications

@MainActor
final class Notifier {
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorization() {
        guard isAvailable else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    func post(_ notices: [Notice]) {
        guard isAvailable else { return }
        for notice in notices {
            let content = UNMutableNotificationContent()
            (content.title, content.body) = Self.text(for: notice)
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    private static func text(for notice: Notice) -> (String, String) {
        switch notice {
        case let .manualExportDue(_, sourceName):
            ("Пора сделать экспорт", "\(sourceName): откройте Backup Everything, там инструкция.")
        case let .connectDestination(_, destinationName):
            ("Пора подключить диск", "«\(destinationName)» давно не получал бэкапы.")
        case let .runFailed(_, sourceName, message):
            ("Бэкап не удался", "\(sourceName): \(message)")
        case let .destinationCaughtUp(_, destinationName):
            ("Диск можно отключать", "«\(destinationName)» получил все накопившиеся бэкапы.")
        case let .copiesMissing(_, sourceName, destinationName):
            ("Копия пропала", "В «\(destinationName)» не нашлось последней копии «\(sourceName)». Делаю новую.")
        }
    }
}
