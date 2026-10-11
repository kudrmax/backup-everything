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

    static func copies(of source: Source, config: Config, state: AppState) -> [CopyPlace] {
        config.destinations(of: source).map { destination in
            guard let newest = state.cachedCopies(sourceId: source.id, destinationId: destination.id)?.copies.max(by: { $0.date < $1.date }) else {
                return CopyPlace(destination: destination, folder: nil, unavailableReason: "No copies yet")
            }
            let folder = AppPaths.expand(destination.path).appendingPathComponent(source.slug).appendingPathComponent(newest.name)
            return CopyPlace(destination: destination, folder: folder, unavailableReason: nil)
        }
    }
}
