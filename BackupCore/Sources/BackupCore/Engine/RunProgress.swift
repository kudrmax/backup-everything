import Foundation

public enum RunProgress: Sendable, Equatable {
    case queued(sourceIds: [UUID])
    case collecting(sourceId: UUID)
    case delivering(sourceId: UUID, destinationId: UUID)
    case finished(sourceId: UUID)
}

public typealias ProgressHandler = @Sendable (RunProgress) -> Void
