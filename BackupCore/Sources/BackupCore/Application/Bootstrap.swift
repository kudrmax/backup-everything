import Foundation

public struct Bootstrap: Sendable {
    public static let selfSourceName = "Настройки Backup Everything"

    private let store: Store
    private let workDirectory: URL

    public init(store: Store, workDirectory: URL) {
        self.store = store
        self.workDirectory = workDirectory
    }

    public func prepare(now: Date) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: store.dataDirectory, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: CoreAssembly.stagingDirectory(in: workDirectory))
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try store.installBundledTemplates()
        guard !store.hasConfig else { return }
        let selfSource = Source(
            name: Self.selfSourceName,
            slug: Slug.make(from: Self.selfSourceName, existing: []),
            kind: .folder(path: store.dataDirectory.path, excludes: []),
            schedule: .daily,
            instructions: "Настройки, история и шаблоны приложения. Выберите назначения, чтобы их можно было восстановить.",
            createdAt: now
        )
        try store.saveConfig(Config(sources: [selfSource]))
    }
}
