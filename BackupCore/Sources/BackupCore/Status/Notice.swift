import Foundation

public enum Notice: Sendable, Equatable {
    case manualExportDue(sourceId: UUID, sourceName: String)
    case connectDestination(destinationId: UUID, destinationName: String)
    case runFailed(sourceId: UUID, sourceName: String, message: String)
    case destinationCaughtUp(destinationId: UUID, destinationName: String)
}

public struct TickResult: Sendable, Equatable {
    public var runs: [RunRecord]
    public var notices: [Notice]

    public init(runs: [RunRecord] = [], notices: [Notice] = []) {
        self.runs = runs
        self.notices = notices
    }
}
