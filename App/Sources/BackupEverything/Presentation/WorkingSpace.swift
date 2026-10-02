import BackupCore
import Foundation

/// How much space the laptop needs for backups to run. They run one at a time, so it is not the sum but the largest
/// of those collected into a temporary folder (a single-step folder is copied directly and takes no space),
/// plus packages already waiting to be written to a disconnected disk.
enum WorkingSpace {
    struct Need: Equatable {
        let bytes: Int64
        let largest: Source?
        let waitingBytes: Int64
    }

    static func need(sources: [Source], lastSizes: [UUID: Int64], waiting: [UUID: Int64]) -> Need {
        let staged = sources.filter { $0.enabled && $0.singleFolder == nil }
        let candidate = staged.max { (lastSizes[$0.id] ?? 0) < (lastSizes[$1.id] ?? 0) }
        let largestBytes = candidate.flatMap { lastSizes[$0.id] } ?? 0
        let largest = largestBytes > 0 ? candidate : nil
        let waitingBytes = waiting.filter { $0.key != largest?.id }.values.reduce(0, +)
        return Need(bytes: largestBytes + waitingBytes, largest: largest, waitingBytes: waitingBytes)
    }

    static func isShort(need: Need, free: Int64?) -> Bool {
        free.map { $0 < need.bytes } ?? false
    }

    static func line(need: Need, free: Int64?) -> String {
        let free = free.map { " · \(Texts.bytes($0)) free" } ?? ""
        return "Backups need about \(Texts.bytes(need.bytes)) of free space on the laptop\(free)"
    }

    static func details(need: Need) -> String {
        var lines = ["Backups run one at a time, so there must be room for the largest of those collected into a temporary folder."]
        if let largest = need.largest {
            lines.append("The largest is “\(largest.name)”.")
        }
        if need.waitingBytes > 0 {
            lines.append("Another \(Texts.bytes(need.waitingBytes)) is waiting to be written to a disconnected disk.")
        }
        lines.append("Folders that are copied directly take no temporary space.")
        return lines.joined(separator: "\n")
    }
}
