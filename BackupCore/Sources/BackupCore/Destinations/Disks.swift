import DiskArbitration
import Foundation

public enum DiskLocation: Equatable, Sendable {
    case systemDisk
    /// On an external disk that is not connected now.
    case notConnected
    case connected(DiskIdentity)
    /// A disk is connected, but which one could not be read; it is read again at the next check.
    case unidentified(name: String)
}

public protocol DiskLocating: Sendable {
    func location(of url: URL) -> DiskLocation
}

public enum DiskIdentityError: Error, Equatable {
    case unreadable
}

public protocol VolumeIdentityReading: Sendable {
    /// Throws when the identity cannot be read; a disk that has no UUID is read as `uuid: nil`.
    func identity(ofVolumeAt mountPoint: URL) throws -> DiskIdentity
}

public struct SystemDisks: DiskLocating {
    private let mounts: VolumeMounts
    private let volumes: any VolumeIdentityReading

    public init(mounts: VolumeMounts = VolumeMounts(), volumes: any VolumeIdentityReading = DiskArbitrationVolumes()) {
        self.mounts = mounts
        self.volumes = volumes
    }

    public func location(of url: URL) -> DiskLocation {
        switch mounts.placement(of: url) {
        case .systemDisk: .systemDisk
        case .volume(_, isMounted: false): .notConnected
        case let .volume(mountPoint, isMounted: true): location(ofVolumeAt: mountPoint)
        }
    }

    private func location(ofVolumeAt mountPoint: URL) -> DiskLocation {
        do {
            return .connected(try volumes.identity(ofVolumeAt: mountPoint))
        } catch {
            return .unidentified(name: mountPoint.lastPathComponent)
        }
    }
}

/// The Volume UUID as Disk Arbitration reads it from the disk. Foundation reports the same one for APFS, HFS+ and exFAT,
/// but for FAT32 and FAT16 a new random one on every mount; Disk Arbitration makes it from their serial number.
public struct DiskArbitrationVolumes: VolumeIdentityReading {
    public init() {}

    public func identity(ofVolumeAt mountPoint: URL) throws -> DiskIdentity {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, mountPoint as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any] else { throw DiskIdentityError.unreadable }
        let name = description[kDADiskDescriptionVolumeNameKey as String] as? String ?? mountPoint.lastPathComponent
        return DiskIdentity(uuid: uuid(description[kDADiskDescriptionVolumeUUIDKey as String]), name: name)
    }

    private func uuid(_ value: Any?) -> String? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() else { return nil }
        return CFUUIDCreateString(kCFAllocatorDefault, (value as! CFUUID)) as String?
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
    /// A disk is connected, but which one could not be read: it is neither taken for the confirmed disk nor for another one.
    case unidentified(name: String)
    /// The folder's disk is not APFS (`format` as people know it), so it is not used at all, whichever disk it is.
    case unsupportedFormat(name: String, format: String)

    public static func of(_ location: DiskLocation, expected: DiskIdentity?) -> DiskCheck {
        switch (location, expected) {
        case (.systemDisk, _): .notNeeded
        case let (.unidentified(name), _): .unidentified(name: name)
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
        case .notNeeded, .confirmed, .notConnected, .unidentified, .unsupportedFormat: nil
        }
    }
}
