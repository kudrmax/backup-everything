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
        switch source.kind {
        case let .folder(path, _) where !path.isEmpty, let .device(path, _) where !path.isEmpty:
            return AppPaths.expand(path)
        default:
            return nil
        }
    }

    static func copies(of source: Source, config: Config, state: AppState) -> [CopyPlace] {
        config.destinations(of: source).map { destination in
            guard case let .localFolder(path) = destination.kind else {
                return CopyPlace(destination: destination, folder: nil, unavailableReason: "Копия в облаке — в Finder не открыть")
            }
            guard let snapshot = state.lastDeliveredSnapshot(sourceId: source.id, destinationId: destination.id) else {
                return CopyPlace(destination: destination, folder: nil, unavailableReason: "Копий ещё нет")
            }
            let folder = AppPaths.expand(path).appendingPathComponent(source.slug).appendingPathComponent(snapshot)
            return CopyPlace(destination: destination, folder: folder, unavailableReason: nil)
        }
    }
}
