import Foundation

enum AppPaths {
    private static let overrideVariable = "BACKUP_EVERYTHING_HOME"

    static var dataDirectory: URL {
        dataDirectory(environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    static var workDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return workDirectory(environment: ProcessInfo.processInfo.environment, applicationSupport: support)
    }

    static func dataDirectory(environment: [String: String], home: URL) -> URL {
        if let root = overrideRoot(environment) { return root.appendingPathComponent("data", isDirectory: true) }
        return home.appendingPathComponent("BackupEverything", isDirectory: true)
    }

    static func workDirectory(environment: [String: String], applicationSupport: URL) -> URL {
        if let root = overrideRoot(environment) { return root.appendingPathComponent("work", isDirectory: true) }
        return applicationSupport.appendingPathComponent("BackupEverything", isDirectory: true)
    }

    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private static func overrideRoot(_ environment: [String: String]) -> URL? {
        environment[overrideVariable].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
