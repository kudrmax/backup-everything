import Foundation

public struct Bootstrap: Sendable {
    public static let selfSourceDescription = "Settings, history and templates of the app itself. Needed to restore it on another Mac."
    public static let selfSourceName = "Backup Everything settings"

    private let store: Store
    private let workDirectory: URL

    public init(store: Store, workDirectory: URL) {
        self.store = store
        self.workDirectory = workDirectory
    }

    public func prepare(now: Date) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: store.dataDirectory, withIntermediateDirectories: true)
        try? FolderRemoval().remove(CoreAssembly.stagingDirectory(in: workDirectory).path)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try store.installBundledTemplates()
        guard !store.hasConfig else { return }
        let selfSource = Source(
            name: Self.selfSourceName,
            slug: Slug.make(from: Self.selfSourceName, existing: []),
            steps: [.folder(store.dataDirectory.path)],
            schedule: .daily,
            description: Self.selfSourceDescription,
            createdAt: now
        )
        try store.saveConfig(Config(sources: [selfSource]))
    }
}
