import BackupCore
import Foundation

/// Whether the “Save space” switch of a source can work with the chosen destinations.
struct SpaceSaving: Equatable {
    /// Destinations where every copy is stored in full whatever the switch says.
    let fullCopiesIn: [String]
    let isPossible: Bool

    static let tip = "Files that haven’t changed since an earlier copy take no extra space; every copy still opens as a complete folder. "
        + "Works on Mac-formatted (APFS) disks, not in the cloud."

    /// `sharing` remembers what each local disk allowed when it was last connected; a disk never seen connected counts as able.
    static func of(_ destinations: [Destination], sharing: [UUID: Bool]) -> SpaceSaving {
        let unable = destinations.filter { destination in
            switch destination.kind {
            case .rclone: true
            case .localFolder: sharing[destination.id] == false
            }
        }
        return SpaceSaving(
            fullCopiesIn: unable.map(\.name),
            isPossible: !destinations.isEmpty && unable.count < destinations.count
        )
    }

    var note: String? {
        guard !fullCopiesIn.isEmpty else { return nil }
        let names = fullCopiesIn.map { "“\($0)”" }.joined(separator: ", ")
        return isPossible ? "full copies in \(names)" : "not possible in \(names)"
    }
}
