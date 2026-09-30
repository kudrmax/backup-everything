import Foundation

public enum ExpectedEvery: Codable, Sendable, Equatable {
    case always
    case days(Int)
}

public enum DestinationKind: Codable, Sendable, Equatable {
    case localFolder(path: String)
    case rclone(remote: String, path: String)
}

public struct Destination: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: DestinationKind
    public var expectedEvery: ExpectedEvery

    public init(id: UUID = UUID(), name: String, kind: DestinationKind, expectedEvery: ExpectedEvery = .always) {
        self.id = id
        self.name = name
        self.kind = kind
        self.expectedEvery = expectedEvery
    }
}
