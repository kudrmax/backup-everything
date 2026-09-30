import Foundation

public struct IconStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func add(_ png: Data) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString.lowercased()).png"
        try png.write(to: url(for: name), options: .atomic)
        return name
    }

    public func url(for name: String) -> URL {
        directory.appendingPathComponent((name as NSString).lastPathComponent)
    }

    public func removeUnused(keeping used: Set<String>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where !used.contains(name) {
            try? FileManager.default.removeItem(at: url(for: name))
        }
    }
}
