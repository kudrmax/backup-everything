import Foundation

public protocol SourceProvider: Sendable {
    func collect(at date: Date) async throws -> Payload
    func finish(_ payload: Payload, deliveredEverywhere: Bool)
}
