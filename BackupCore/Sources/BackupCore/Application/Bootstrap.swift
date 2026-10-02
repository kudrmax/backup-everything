import Foundation

public struct Bootstrap: Sendable {
    public static let selfSourceDescription = "Settings, history and templates of the app itself. Needed to restore it on another Mac."
    public static let selfSourceName = "Backup Everything settings"

    private let store: Store
    private let workDirectory: URL
    private let trash: ManualExportInbox.Trash

    public init(
        store: Store,
        workDirectory: URL,
        trash: @escaping ManualExportInbox.Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.store = store
        self.workDirectory = workDirectory
        self.trash = { url in try FolderRemoval().trash(url, using: trash) }
    }

    public func prepare(now: Date) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: store.dataDirectory, withIntermediateDirectories: true)
        let staging = CoreAssembly.stagingDirectory(in: workDirectory)
        StepProcessRecord.stopLeftovers(under: staging)
        for run in (try? fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [] {
            try? WorkFolders(root: run).discard(using: trash)
        }
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
