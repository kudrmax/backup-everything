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
        case let .deviceDue(_, sourceName):
            ("Time to connect the device", "Connect “\(sourceName)” with a cable and the backup starts on its own.")
        case let .deviceCanBeUnplugged(_, sourceName):
            ("Safe to disconnect", "The backup of “\(sourceName)” is done, you can disconnect the device.")
        case let .manualExportDue(_, sourceName):
            ("Time to export", "\(sourceName): open Backup Everything for instructions.")
        case let .connectDestination(_, destinationName, onlyCopyOf):
            ConnectReminder.notice(destinationName: destinationName, onlyCopyOf: onlyCopyOf)
        case let .runFailed(_, sourceName, message):
            ("Backup failed", "\(sourceName): \(message)")
        case let .destinationCaughtUp(_, destinationName):
            ("Safe to disconnect the disk", "“\(destinationName)” has received all pending backups.")
        case let .copiesMissing(_, sourceName, destinationName):
            ("Copy missing", "The latest copy of “\(sourceName)” was not found on “\(destinationName)”. Making a new one.")
        }
    }
}
