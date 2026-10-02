import Foundation

@MainActor
protocol FolderWatching: AnyObject {
    func stop()
}

@MainActor
final class FolderWatcher: FolderWatching {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping @MainActor () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated { onChange() }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
    }

    func stop() {
        source.cancel()
    }
}
