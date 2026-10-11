import Foundation

public enum ExpectedEvery: Codable, Sendable, Equatable {
    case always
    case days(Int)
}

public enum DestinationKind: Codable, Sendable, Equatable {
    case localFolder(path: String)

    private enum CodingKeys: String, CodingKey {
        case localFolder, rclone
    }

    private enum LocalFolderKeys: String, CodingKey {
        case path
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.rclone) {
            throw DecodingError.dataCorruptedError(forKey: .rclone, in: container, debugDescription: "Cloud destinations are not supported by this version.")
        }
        let folder = try container.nestedContainer(keyedBy: LocalFolderKeys.self, forKey: .localFolder)
        self = .localFolder(path: try folder.decode(String.self, forKey: .path))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var folder = container.nestedContainer(keyedBy: LocalFolderKeys.self, forKey: .localFolder)
        if case let .localFolder(path) = self { try folder.encode(path, forKey: .path) }
    }
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

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, expectedEvery
    }

    public var path: String {
        if case let .localFolder(path) = kind { return path }
        return ""
    }
}
