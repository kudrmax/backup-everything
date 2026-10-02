import Foundation

public typealias StatusHandler = @Sendable (String) -> Void

public protocol SourceProvider: Sendable {
    func collect(at date: Date, status: @escaping StatusHandler) async throws -> Payload
    func finish(_ payload: Payload, deliveredEverywhere: Bool) throws
}

public extension SourceProvider {
    func collect(at date: Date) async throws -> Payload {
        try await collect(at: date, status: { _ in })
    }
}
