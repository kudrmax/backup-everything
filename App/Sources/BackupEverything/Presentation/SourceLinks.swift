import BackupCore
import Foundation

struct CopyPlace: Equatable, Identifiable {
    let destination: Destination
    let folder: URL?
    let unavailableReason: String?

    var id: UUID { destination.id }
}

enum SourceLinks {
    static func original(of source: Source) -> URL? {
        for step in source.steps {
            if case let .folder(path, _) = step.kind, !path.isEmpty { return AppPaths.expand(path) }
        }
        return nil
    }

    static func copies(of source: Source, config: Config, state: AppState) -> [CopyPlace] {
        config.destinations(of: source).map { destination in
            guard case let .localFolder(path) = destination.kind else {
                return CopyPlace(destination: destination, folder: nil, unavailableReason: "The copy is in the cloud and can’t be opened in Finder")
            }
            guard let snapshot = state.lastDeliveredSnapshot(sourceId: source.id, destinationId: destination.id) else {
                return CopyPlace(destination: destination, folder: nil, unavailableReason: "No copies yet")
            }
            let folder = AppPaths.expand(path).appendingPathComponent(source.slug).appendingPathComponent(snapshot)
            return CopyPlace(destination: destination, folder: folder, unavailableReason: nil)
        }
    }
}
