import BackupCore
import Foundation

enum SourceStage: Equatable {
    case queued
    case collecting
    case delivering(destinationId: UUID)
}

struct ActivityTracker {
    private var stages: [UUID: SourceStage] = [:]

    func stage(of sourceId: UUID) -> SourceStage? {
        stages[sourceId]
    }

    var current: UUID? {
        stages.first { $0.value != .queued }?.key
    }

    var waitingCount: Int {
        stages.values.filter { $0 == .queued }.count
    }

    mutating func apply(_ event: RunProgress) {
        switch event {
        case let .queued(sourceIds):
            for id in sourceIds where stages[id] == nil {
                stages[id] = .queued
            }
        case let .collecting(sourceId):
            stages[sourceId] = .collecting
        case let .delivering(sourceId, destinationId):
            stages[sourceId] = .delivering(destinationId: destinationId)
        case let .finished(sourceId):
            stages[sourceId] = nil
        }
    }

    mutating func reset() {
        stages = [:]
    }
}
