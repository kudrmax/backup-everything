import BackupCore
import Foundation

struct CopyPlace: Equatable, Identifiable {
    let destination: Destination
    let folder: URL?
    let unavailableReason: String?

    var id: UUID { destination.id }

    var tip: String {
        unavailableReason.map { "Open copy: \(Self.lowercasedFirst($0))" } ?? "Show copy in Finder"
    }

    var menuTitle: String {
        unavailableReason.map { "\(destination.name) — \(Self.lowercasedFirst($0))" } ?? destination.name
    }

    private static func lowercasedFirst(_ text: String) -> String {
        text.prefix(1).lowercased() + text.dropFirst()
    }
}

enum SourceLinks {
    static func original(of source: Source) -> URL? {
        for step in source.steps {
            if case let .folder(path, _) = step.kind, !path.isEmpty { return AppPaths.expand(path) }
        }
        return nil
    }

    /// `disks`: whether the disk of each destination is the confirmed one; a copy elsewhere is not opened.
    static func copies(of source: Source, config: Config, state: AppState, disks: [UUID: DiskCheck] = [:]) -> [CopyPlace] {
        config.destinations(of: source).map { destination in
            guard case let .localFolder(path) = destination.kind else {
                return CopyPlace(destination: destination, folder: nil, unavailableReason: "The copy is in the cloud and can’t be opened in Finder")
            }
            guard let snapshot = state.lastDeliveredSnapshot(sourceId: source.id, destinationId: destination.id) else {
                return CopyPlace(destination: destination, folder: nil, unavailableReason: "No copies yet")
            }
            if let reason = DiskTexts.copyUnavailable(disks[destination.id]) {
                return CopyPlace(destination: destination, folder: nil, unavailableReason: reason)
            }
            let folder = AppPaths.expand(path).appendingPathComponent(source.slug).appendingPathComponent(snapshot)
            return CopyPlace(destination: destination, folder: folder, unavailableReason: nil)
        }
    }
}
