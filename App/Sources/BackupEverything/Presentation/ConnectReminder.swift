import Foundation

/// Texts about a “from time to time” disk: why it asks to be connected and what happens to the missed backups.
enum ConnectReminder {
    static func notice(destinationName: String, onlyCopyOf sources: [String]) -> (title: String, body: String) {
        let title = "Connect “\(destinationName)”"
        guard !sources.isEmpty else {
            return (title, "The disk hasn’t been connected for a while. Copies are on other disks, but this one needs updating too.")
        }
        let names = sources.map { "“\($0)”" }.joined(separator: ", ")
        let body = sources.count == 1
            ? "The backup of \(names) exists nowhere else. It will be written as soon as you connect the disk."
            : "The backups of \(names) exist nowhere else. They will be written as soon as you connect the disk."
        return (title, body)
    }

    static func waitingLine(elsewhere: Bool, otherDestinations: [String]) -> String {
        guard elsewhere, !otherDestinations.isEmpty else { return "this backup exists nowhere else — connect the disk" }
        return "a copy is on " + otherDestinations.map { "“\($0)”" }.joined(separator: ", ")
    }

    static let settingsExplanation = "Until the period runs out, there are no reminders, as long as the missed backups are on other disks. If a backup exists nowhere else, you’ll be reminded right away. Once connected, the disk gets a fresh copy of every source."
}
