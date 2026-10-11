import BackupCore
import Foundation

enum ExcessCopiesText {
    static let intro = "These copies are older than the retention rules allow. The app never deletes copies; run the command to hand them back to you and move them to the Trash."
    static let disconnected = "connect the disk to get the command"

    static func summary(_ excess: [ExcessCopies], config: Config) -> String? {
        let count = excess.reduce(0) { $0 + $1.items.count }
        guard count > 0 else { return nil }
        let bytes = excess.reduce(Int64(0)) { $0 + $1.totalBytes }
        return "\(Texts.copies(count)) beyond the rules" + (bytes > 0 ? ", up to \(Texts.bytes(bytes))" : "")
    }

    static func title(_ excess: ExcessCopies, config: Config) -> String {
        let source = config.source(excess.sourceId)?.name ?? "?"
        let destination = config.destination(excess.destinationId)?.name ?? "?"
        var text = "\(source) on \(destination): \(Texts.copies(excess.items.count))"
        if excess.totalBytes > 0 { text += ", up to \(Texts.bytes(excess.totalBytes))" }
        if let asOf = excess.asOf { text += " (as seen \(Texts.relative(asOf)))" }
        return text
    }
}
