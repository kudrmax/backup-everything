import BackupCore
import Foundation

enum NoticeText {
    static func of(_ notice: Notice) -> (title: String, body: String) {
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
