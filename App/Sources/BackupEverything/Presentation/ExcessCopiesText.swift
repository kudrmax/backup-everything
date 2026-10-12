import BackupCore
import Foundation

enum ExcessCopiesText {
    static let intro = "These copies are older than the retention rules allow; unfinished attempts are folders of interrupted backups, never written into again. The app never deletes copies; run the command to hand them back to you and move them to the Trash."
    static let disconnected = "connect the disk to get the command"
    static let whileRunning = "Commands appear when no backup is running."

    /// An unfinished attempt may be the folder a running backup is writing: removing it would break that copy.
    static func command(for excess: ExcessCopies, user: String, backupRunning: Bool) -> String? {
        backupRunning ? nil : ExcessCopies.command(for: excess.items, user: user)
    }

    static func summary(_ excess: [ExcessCopies], config: Config) -> String? {
        let copies = excess.reduce(0) { $0 + $1.copyCount }
        let attempts = excess.reduce(0) { $0 + $1.unfinishedCount }
        guard copies + attempts > 0 else { return nil }
        let bytes = excess.reduce(Int64(0)) { $0 + $1.totalBytes }
        let parts = (copies > 0 ? ["\(Texts.copies(copies)) beyond the rules"] : []) + (attempts > 0 ? [unfinished(attempts)] : [])
        return parts.joined(separator: " and ") + (bytes > 0 ? ", up to \(Texts.bytes(bytes))" : "")
    }

    static func title(_ excess: ExcessCopies, config: Config) -> String {
        let source = config.source(excess.sourceId)?.name ?? "?"
        let destination = config.destination(excess.destinationId)?.name ?? "?"
        let parts = (excess.copyCount > 0 ? [Texts.copies(excess.copyCount)] : []) + (excess.unfinishedCount > 0 ? [unfinished(excess.unfinishedCount)] : [])
        var text = "\(source) on \(destination): \(parts.joined(separator: " and "))"
        if excess.totalBytes > 0 { text += ", up to \(Texts.bytes(excess.totalBytes))" }
        if let asOf = excess.asOf { text += " (as seen \(Texts.relative(asOf)))" }
        return text
    }

    private static func unfinished(_ count: Int) -> String {
        "\(count) unfinished \(Texts.plural(count, "attempt", "attempts"))"
    }
}
