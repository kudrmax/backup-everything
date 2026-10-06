import BackupCore
import Foundation

@MainActor
enum DestinationDetails {
    static func text(of destination: Destination, model: AppModel) -> String {
        let condition = model.condition(of: destination)
        var lines = [condition.diskExplanation(destinationName: destination.name) ?? (condition.isConnected ? "Available" : "Not connected now")]
        let waiting = model.waitingSources(for: destination)
        if let caughtUp = model.lastCaughtUp(destination) {
            lines.append("Got everything: \(Texts.relative(caughtUp))")
        }
        lines.append(waiting.isEmpty ? "Nothing waiting for delivery" : "Waiting for delivery: \(waiting.map(\.name).joined(separator: ", "))")
        let unique = waiting.filter { !model.isCoveredElsewhere($0, for: destination) }
        if !unique.isEmpty {
            lines.append("Nowhere else: \(unique.map(\.name).joined(separator: ", ")) — connect the disk")
        } else if let deadline = model.connectDeadline(of: destination), deadline > Date() {
            lines.append("Copies are on other disks — reminder \(Texts.until(deadline))")
        }
        return lines.joined(separator: "\n")
    }
}

/// The orange line under a destination’s name in its settings.
enum DestinationAttention {
    static func text(problem: String?, waiting: [String]) -> String? {
        let parts = [problem, waiting.isEmpty ? nil : "waiting: \(waiting.joined(separator: ", "))"].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A destination in the overview’s bottom line: a connected folder opens in Finder, anything else opens its settings.
enum DestinationLink {
    static func folder(of destination: Destination) -> URL? {
        guard case let .localFolder(path) = destination.kind else { return nil }
        return AppPaths.expand(path)
    }

    static func title(of destination: Destination, used: Int64?, condition: DestinationCondition) -> String {
        [destination.name, used.map(Texts.bytes), condition.problem].compactMap { $0 }.joined(separator: " · ")
    }

    static func finderFolder(of destination: Destination, isConnected: Bool) -> URL? {
        isConnected ? folder(of: destination) : nil
    }

    static func actionTip(for destination: Destination, isConnected: Bool) -> String {
        finderFolder(of: destination, isConnected: isConnected) == nil ? "Click to open settings" : "Click to show in Finder"
    }
}
