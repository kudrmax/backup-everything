import BackupCore
import Foundation

enum DeliveryState: Equatable {
    case delivered
    /// A copy is there, but it is older than the destination's rhythm.
    case outdated
    case failed
    case waiting
    /// No copy has been there yet.
    case none
    /// Not proven either way: before the first check, or the source is not checked (disabled).
    case unconfirmed

    var mark: String? {
        switch self {
        case .delivered: "checkmark.circle.fill"
        case .outdated: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .waiting: "clock.fill"
        case .none, .unconfirmed: nil
        }
    }
}

enum DeliveryText {
    static func details(
        destinationName: String,
        isWriting: Bool,
        state: DeliveryState,
        last: (date: Date, outcome: DeliveryOutcome)?,
        now: Date = Date(),
        waitingLine: () -> String
    ) -> String {
        if isWriting { return "\(destinationName)\nwriting…" }
        return switch state {
        case .delivered:
            "\(destinationName)\ndelivered \(last.map { Texts.relative($0.date, to: now) } ?? "")"
        case .outdated:
            "\(destinationName)\ndelivered \(last.map { Texts.relative($0.date, to: now) } ?? "")\nthis copy is older than expected"
        case .failed:
            "\(destinationName)\n\(last.map { Texts.outcome($0.outcome) } ?? "error")\nretrying later"
        case .waiting:
            "\(destinationName)\nwaiting to be connected\n\(waitingLine())"
        case .none:
            "\(destinationName)\nno copies yet"
        case .unconfirmed:
            "\(destinationName)\n" + (last.map { "delivered \(Texts.relative($0.date, to: now)) · " } ?? "") + "not checked yet"
        }
    }
}
