import Foundation

public enum StoreError: Error, Equatable, LocalizedError {
    case corrupted(file: String)
    case unreadable(file: String)
    case unsupportedVersion(file: String, version: Int)

    public var errorDescription: String? {
        switch self {
        case let .corrupted(file):
            "The file \(file) is damaged and cannot be read."
        case let .unreadable(file):
            "Could not read the file \(file). Check the access permissions."
        case let .unsupportedVersion(file, version):
            "The file \(file) was created by a newer version of the app (format \(version))."
        }
    }
}

public struct Store: Sendable {
    public let dataDirectory: URL

    public init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    public var configURL: URL { dataDirectory.appendingPathComponent("config.json") }
    public var stateURL: URL { dataDirectory.appendingPathComponent("state.json") }
    public var historyDirectory: URL { dataDirectory.appendingPathComponent("history", isDirectory: true) }
    public var templatesDirectory: URL { dataDirectory.appendingPathComponent("templates", isDirectory: true) }
    public var iconsDirectory: URL { dataDirectory.appendingPathComponent("icons", isDirectory: true) }

    public var hasConfig: Bool {
        FileManager.default.fileExists(atPath: configURL.path)
    }

    public func loadConfig() throws -> Config {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return Config() }
        guard let data = try? Data(contentsOf: configURL) else {
            throw StoreError.unreadable(file: configURL.lastPathComponent)
        }
        guard let config = try? JSONCoding.decoder().decode(Config.self, from: data) else {
            throw StoreError.corrupted(file: configURL.lastPathComponent)
        }
        guard config.schemaVersion <= Config.currentSchemaVersion else {
            throw StoreError.unsupportedVersion(file: configURL.lastPathComponent, version: config.schemaVersion)
        }
        var current = config
        current.schemaVersion = Config.currentSchemaVersion
        return current
    }

    public func saveConfig(_ config: Config) throws {
        try keepCopyOfOlderConfig()
        try write(config, to: configURL)
    }

    /// Before the first write in the new format the old file is kept alongside: with it you can go back to the previous version of the app.
    private func keepCopyOfOlderConfig() throws {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["schemaVersion"] as? Int,
              version < Config.currentSchemaVersion else { return }
        let copy = dataDirectory.appendingPathComponent("config.v\(version).json")
        guard !FileManager.default.fileExists(atPath: copy.path) else { return }
        try data.write(to: copy, options: .atomic)
    }

    public func loadState() throws -> AppState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return AppState() }
        guard let data = try? Data(contentsOf: stateURL) else {
            throw StoreError.unreadable(file: stateURL.lastPathComponent)
        }
        guard let state = try? JSONCoding.decoder().decode(AppState.self, from: data) else {
            try setAside(stateURL)
            return AppState()
        }
        guard state.schemaVersion <= AppState.currentSchemaVersion else {
            throw StoreError.unsupportedVersion(file: stateURL.lastPathComponent, version: state.schemaVersion)
        }
        return state
    }

    public func saveState(_ state: AppState) throws {
        try write(state, to: stateURL)
    }

    public func appendRun(_ record: RunRecord) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let url = historyDirectory.appendingPathComponent("\(Self.month(of: record.startedAt)).jsonl")
        var line = try JSONCoding.encoder(pretty: false).encode(record)
        line.append(0x0A)
        guard fileManager.fileExists(atPath: url.path) else {
            try line.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if size > 0 {
            try handle.seek(toOffset: size - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) {
                line.insert(0x0A, at: 0)
            }
        }
        try handle.write(contentsOf: line)
    }

    public func loadRuns(limit: Int? = nil) -> [RunRecord] {
        let decoder = JSONCoding.decoder()
        var records: [RunRecord] = []
        for url in jsonFiles(in: historyDirectory, extension: "jsonl").sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: url) else { continue }
            let month = data.split(separator: 0x0A).compactMap { try? decoder.decode(RunRecord.self, from: Data($0)) }
            records.append(contentsOf: month.sorted { $0.startedAt > $1.startedAt })
            if let limit, records.count >= limit { return Array(records.prefix(limit)) }
        }
        return records
    }

    public func loadTemplates() -> [SourceTemplate] {
        let decoder = JSONCoding.decoder()
        return jsonFiles(in: templatesDirectory, extension: "json")
            .compactMap { try? decoder.decode(SourceTemplate.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func installBundledTemplates() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)
        for template in BundledTemplates.all {
            let target = templatesDirectory.appendingPathComponent("\(template.id).json")
            if !fileManager.fileExists(atPath: target.path) {
                try JSONCoding.encoder().encode(template).write(to: target, options: .atomic)
            }
        }
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(value).write(to: url, options: .atomic)
    }

    private func setAside(_ url: URL) throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let target = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        try FileManager.default.moveItem(at: url, to: target)
    }

    private func jsonFiles(in directory: URL, extension ext: String) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == ext }
    }

    private static func month(of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return String(format: "%04d-%02d", calendar.component(.year, from: date), calendar.component(.month, from: date))
    }
}
