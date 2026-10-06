import Foundation

public enum ExpectedEvery: Codable, Sendable, Equatable {
    case always
    case days(Int)
}

public enum DestinationKind: Codable, Sendable, Equatable {
    case localFolder(path: String)
    case rclone(remote: String, path: String)
}

/// The disk a folder destination lives on, as macOS reports it. An external disk is recognised by it, not by its name:
/// any disk can be named like another one.
public struct DiskIdentity: Codable, Sendable, Equatable {
    /// The Volume UUID; `nil` when the disk reports none, and then exactly that was accepted for the destination.
    public var uuid: String?
    /// What the disk was called when it was read; only for showing.
    public var name: String

    public init(uuid: String?, name: String) {
        self.uuid = uuid
        self.name = name
    }

    public func isSameDisk(as other: DiskIdentity) -> Bool {
        uuid == other.uuid
    }
}

public struct Destination: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: DestinationKind
    public var expectedEvery: ExpectedEvery
    /// The disk a folder on an external disk was confirmed on; `nil` until the person confirms it.
    public var disk: DiskIdentity?

    public init(id: UUID = UUID(), name: String, kind: DestinationKind, expectedEvery: ExpectedEvery = .always, disk: DiskIdentity? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.expectedEvery = expectedEvery
        self.disk = disk
    }

    public var location: DestinationLocation {
        DestinationLocation(kind: kind, disk: disk.map { DestinationLocation.Disk(uuid: $0.uuid) })
    }
}

/// Where the copies of a destination are: its folder or remote, and the disk the folder was confirmed on. What is known
/// about copies holds only for this place; the name, the rhythm and the name the disk had when read are not part of it.
public struct DestinationLocation: Codable, Sendable, Equatable {
    public struct Disk: Codable, Sendable, Equatable {
        /// The Volume UUID; `nil` when the disk reports none.
        public var uuid: String?
    }

    public var kind: DestinationKind
    /// The confirmed disk; `nil` while none is confirmed.
    public var disk: Disk?
}
