import BackupCore
import Foundation

enum SourceStage: Equatable {
    case queued
    case collecting
    case delivering(destinationId: UUID)
}

struct ActivityTracker {
    private var stages: [UUID: SourceStage] = [:]
    private var starts: [UUID: Date] = [:]
    private var statuses: [UUID: String] = [:]
    private var steps: [UUID: (index: Int, count: Int)] = [:]

    func stage(of sourceId: UUID) -> SourceStage? {
        stages[sourceId]
    }

    func startedAt(of sourceId: UUID) -> Date? {
        starts[sourceId]
    }

    func status(of sourceId: UUID) -> String? {
        statuses[sourceId]
    }

    func step(of sourceId: UUID) -> (index: Int, count: Int)? {
        steps[sourceId]
    }

    var active: Set<UUID> {
        Set(stages.keys)
    }

    var current: UUID? {
        stages.first { $0.value != .queued }?.key
    }

    var waitingCount: Int {
        stages.values.filter { $0 == .queued }.count
    }

    mutating func apply(_ event: RunProgress, at date: Date = Date()) {
        switch event {
        case let .queued(sourceIds):
            for id in sourceIds where stages[id] == nil {
                stages[id] = .queued
            }
        case let .collecting(sourceId):
            stages[sourceId] = .collecting
            starts[sourceId] = starts[sourceId] ?? date
        case let .status(sourceId, text):
            statuses[sourceId] = text
        case let .step(sourceId, index, count):
            steps[sourceId] = (index, count)
        case let .delivering(sourceId, destinationId):
            stages[sourceId] = .delivering(destinationId: destinationId)
            starts[sourceId] = starts[sourceId] ?? date
            statuses[sourceId] = nil
        case let .finished(sourceId):
            stages[sourceId] = nil
            starts[sourceId] = nil
            statuses[sourceId] = nil
            steps[sourceId] = nil
        }
    }

    mutating func reset() {
        stages = [:]
        starts = [:]
        statuses = [:]
        steps = [:]
    }
}
