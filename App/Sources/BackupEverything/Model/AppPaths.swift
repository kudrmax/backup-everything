import Foundation

enum AppPaths {
    private static let overrideVariable = "BACKUP_EVERYTHING_HOME"
    private static let directRsyncVariable = "BACKUP_EVERYTHING_DIRECT_RSYNC"

    static var dataDirectory: URL {
        dataDirectory(environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    static var workDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return workDirectory(environment: ProcessInfo.processInfo.environment, applicationSupport: support)
    }

    /// The sandbox writes copies straight into the destination folders, without the receiver and the backup account.
    static var writesDirectly: Bool {
        writesDirectly(environment: ProcessInfo.processInfo.environment)
    }

    /// Only together with the sandbox home: with the real settings it would leave the copies unprotected.
    static func writesDirectly(environment: [String: String]) -> Bool {
        environment[directRsyncVariable] != nil && overrideRoot(environment) != nil
    }

    static func dataDirectory(environment: [String: String], home: URL) -> URL {
        if let root = overrideRoot(environment) { return root.appendingPathComponent("data", isDirectory: true) }
        return home.appendingPathComponent("BackupEverything", isDirectory: true)
    }

    static func workDirectory(environment: [String: String], applicationSupport: URL) -> URL {
        if let root = overrideRoot(environment) { return root.appendingPathComponent("work", isDirectory: true) }
        return applicationSupport.appendingPathComponent("BackupEverything", isDirectory: true)
    }

    static var setupScript: String {
        setupScript(bundleURL: Bundle.main.bundleURL, resourceURL: Bundle.main.resourceURL)
    }

    /// The script ships inside the app; a `swift build` binary has no bundle and uses the one in the repository.
    static func setupScript(bundleURL: URL, resourceURL: URL?) -> String {
        guard bundleURL.pathExtension == "app", let resourceURL else { return "scripts/setup-storage.sh" }
        return resourceURL.appendingPathComponent("setup-storage.sh").path
    }

    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private static func overrideRoot(_ environment: [String: String]) -> URL? {
        environment[overrideVariable].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
