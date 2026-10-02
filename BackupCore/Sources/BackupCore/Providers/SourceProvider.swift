import Foundation

public typealias StatusHandler = @Sendable (String) -> Void

/// Where the copies of a collected payload went.
public enum PayloadDelivery: Sendable, Equatable {
    case everywhere
    /// To some destinations: a copy exists, the others catch up from it later.
    case partly
    /// Not delivered at all, or the payload turned out unfit for a copy.
    case nowhere
}

public protocol SourceProvider: Sendable {
    func collect(at date: Date, status: @escaping StatusHandler) async throws -> Payload
    func finish(_ payload: Payload, delivered: PayloadDelivery) throws
}

public extension SourceProvider {
    func collect(at date: Date) async throws -> Payload {
        try await collect(at: date, status: { _ in })
    }
}
