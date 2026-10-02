import Foundation

public struct FolderSource: SourceProvider {
    private let path: String
    private let excludes: [String]

    public init(path: String, excludes: [String]) {
        self.path = path
        self.excludes = excludes
    }

    public func collect(at date: Date, status: @escaping StatusHandler) async throws -> Payload {
        let root = Paths.url(path)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw SourceError.pathMissing(root.path)
        }
        return Payload(root: root, excludes: excludes, collectedAt: date)
    }

    public func finish(_ payload: Payload, delivered: PayloadDelivery) {}
}
