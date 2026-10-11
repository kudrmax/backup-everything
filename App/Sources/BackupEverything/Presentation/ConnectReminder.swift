import Foundation

/// Texts about a “from time to time” disk: when and why it asks to be connected.
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

    static let settingsExplanation = "The reminder to connect the disk comes once the newest copy of a source on it is older than this period, and right away for a source that has no copy there yet. Once connected, the disk gets a fresh copy of every source."
}
