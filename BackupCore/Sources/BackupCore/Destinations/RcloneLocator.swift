import Foundation

public struct RcloneLocator: Sendable {
    private let candidates: [String]

    public init(candidates: [String] = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone"]) {
        self.candidates = candidates
    }

    public func find() -> URL? {
        candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}
