import Foundation

enum AppPaths {
    private static let overrideVariable = "BACKUP_EVERYTHING_HOME"

    static var dataDirectory: URL {
        if let root = overrideRoot { return root.appendingPathComponent("data", isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BackupEverything", isDirectory: true)
    }

    static var workDirectory: URL {
        if let root = overrideRoot { return root.appendingPathComponent("work", isDirectory: true) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("BackupEverything", isDirectory: true)
    }

    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private static var overrideRoot: URL? {
        ProcessInfo.processInfo.environment[overrideVariable].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
