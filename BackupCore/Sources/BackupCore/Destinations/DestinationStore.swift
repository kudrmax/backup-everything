import Foundation

public enum DestinationError: Error, Equatable, LocalizedError {
    case unavailable
    case outOfSpace
    case rcloneMissing
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Назначение недоступно."
        case .outOfSpace:
            "В назначении закончилось место."
        case .rcloneMissing:
            "rclone не установлен. Установите его командой «brew install rclone»."
        case let .commandFailed(output):
            "rclone завершился с ошибкой: \(output)"
        }
    }
}

public protocol DestinationStore: Sendable {
    func isAvailable() async -> Bool
    func listSnapshots(sourceSlug: String) async throws -> [Snapshot]
    func removeIncomplete(sourceSlug: String) async throws
    func write(_ payload: Payload, manifest: SnapshotManifest, sourceSlug: String, snapshotName: String) async throws
    func delete(_ snapshot: Snapshot, sourceSlug: String) async throws
    /// Папка на этом компьютере с содержимым копии (вместе с `_snapshot.json`). Облако скачивает её в `scratch`.
    func materialize(_ snapshot: Snapshot, sourceSlug: String, scratch: URL) async throws -> URL
    func usedBytes() async throws -> Int64
}
