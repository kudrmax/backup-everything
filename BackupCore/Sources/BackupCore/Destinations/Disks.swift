import Foundation

public enum DiskLocation: Equatable, Sendable {
    case systemDisk
    /// On an external disk that is not connected now.
    case notConnected
    case connected(DiskIdentity)
}

public protocol DiskLocating: Sendable {
    func location(of url: URL) -> DiskLocation
}

public struct SystemDisks: DiskLocating {
    private let mounts: VolumeMounts

    public init(mounts: VolumeMounts = VolumeMounts()) {
        self.mounts = mounts
    }

    public func location(of url: URL) -> DiskLocation {
        switch mounts.placement(of: url) {
        case .systemDisk: .systemDisk
        case .volume(_, isMounted: false): .notConnected
        case let .volume(mountPoint, isMounted: true): .connected(identity(of: mountPoint))
        }
    }

    /// exFAT and FAT32 have no UUID of their own; macOS reports one made from their serial number.
    private func identity(of mountPoint: URL) -> DiskIdentity {
        let values = try? mountPoint.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey])
        return DiskIdentity(uuid: values?.volumeUUIDString, name: values?.volumeName ?? mountPoint.lastPathComponent)
    }
}

/// Whether a destination’s folder may be touched: a folder on an external disk only on the disk it was confirmed on.
public enum DiskCheck: Equatable, Sendable {
    /// In the cloud or on the system disk: there is no disk to confirm.
    case notNeeded
    case confirmed
    case notConnected
    /// The folder is on an external disk and no disk was confirmed for it yet; `connected` is the disk there now.
    case notConfirmed(connected: DiskIdentity?)
    case otherDisk(DiskIdentity)

    public static func of(_ location: DiskLocation, expected: DiskIdentity?) -> DiskCheck {
        switch (location, expected) {
        case (.systemDisk, _): .notNeeded
        case (.notConnected, nil): .notConfirmed(connected: nil)
        case (.notConnected, _): .notConnected
        case let (.connected(disk), nil): .notConfirmed(connected: disk)
        case let (.connected(disk), expected?): disk.isSameDisk(as: expected) ? .confirmed : .otherDisk(disk)
        }
    }

    public var allowsAccess: Bool {
        self == .notNeeded || self == .confirmed
    }

    /// The disk that can be confirmed for the destination right now.
    public var connectedDisk: DiskIdentity? {
        switch self {
        case let .notConfirmed(connected): connected
        case let .otherDisk(disk): disk
        case .notNeeded, .confirmed, .notConnected: nil
        }
    }
}
