import Foundation

public enum FileMode: String, Codable, Sendable, CaseIterable {
    case single
    case multiple
}

public enum StepKind: Sendable, Equatable {
    case folder(path: String, excludes: [String])
    case command(command: String, timeoutSeconds: Int)
    case file(instructions: String, watchPath: String, filePattern: String, fileMode: FileMode, includeInCopy: Bool, removeOriginal: Bool)
    case device(instructions: String, path: String)
}

extension StepKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case folder, command, file, device
        case manual
    }

    private struct Folder: Codable {
        let path: String
        let excludes: [String]
    }

    private struct Command: Codable {
        let command: String
        let timeoutSeconds: Int
    }

    private struct File: Codable {
        let instructions: String
        let watchPath: String
        let filePattern: String
        let fileMode: FileMode
        let includeInCopy: Bool
        let removeOriginal: Bool
    }

    private struct Device: Codable {
        let instructions: String
        let path: String
    }

    /// Ручной шаг из первой версии «По шагам»: один файл, оригинал уходит.
    private struct LegacyManual: Codable {
        let instructions: String
        let watchPath: String
        let filePattern: String
        let includeInCopy: Bool
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(Folder.self, forKey: .folder) {
            self = .folder(path: value.path, excludes: value.excludes)
        } else if let value = try container.decodeIfPresent(Command.self, forKey: .command) {
            self = .command(command: value.command, timeoutSeconds: value.timeoutSeconds)
        } else if let value = try container.decodeIfPresent(File.self, forKey: .file) {
            self = .file(
                instructions: value.instructions,
                watchPath: value.watchPath,
                filePattern: value.filePattern,
                fileMode: value.fileMode,
                includeInCopy: value.includeInCopy,
                removeOriginal: value.removeOriginal
            )
        } else if let value = try container.decodeIfPresent(Device.self, forKey: .device) {
            self = .device(instructions: value.instructions, path: value.path)
        } else if let value = try container.decodeIfPresent(LegacyManual.self, forKey: .manual) {
            self = .file(
                instructions: value.instructions,
                watchPath: value.watchPath,
                filePattern: value.filePattern,
                fileMode: .single,
                includeInCopy: value.includeInCopy,
                removeOriginal: true
            )
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Неизвестный вид шага"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .folder(path, excludes):
            try container.encode(Folder(path: path, excludes: excludes), forKey: .folder)
        case let .command(command, timeoutSeconds):
            try container.encode(Command(command: command, timeoutSeconds: timeoutSeconds), forKey: .command)
        case let .file(instructions, watchPath, filePattern, fileMode, includeInCopy, removeOriginal):
            try container.encode(
                File(
                    instructions: instructions,
                    watchPath: watchPath,
                    filePattern: filePattern,
                    fileMode: fileMode,
                    includeInCopy: includeInCopy,
                    removeOriginal: removeOriginal
                ),
                forKey: .file
            )
        case let .device(instructions, path):
            try container.encode(Device(instructions: instructions, path: path), forKey: .device)
        }
    }
}

public struct SourceStep: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: StepKind

    public init(id: UUID = UUID(), name: String, kind: StepKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    /// Шаг, который делает человек: приложение только ждёт его результата.
    public var needsHuman: Bool {
        switch kind {
        case .file, .device: true
        case .folder, .command: false
        }
    }

    public var instructions: String? {
        switch kind {
        case let .file(instructions, _, _, _, _, _), let .device(instructions, _): instructions
        case .folder, .command: nil
        }
    }

    public static func folder(_ path: String, excludes: [String] = [], name: String = "Скопировать папку", id: UUID = UUID()) -> SourceStep {
        SourceStep(id: id, name: name, kind: .folder(path: path, excludes: excludes))
    }

    public static func command(_ command: String, timeoutSeconds: Int, name: String = "Выполнить команду", id: UUID = UUID()) -> SourceStep {
        SourceStep(id: id, name: name, kind: .command(command: command, timeoutSeconds: timeoutSeconds))
    }

    public static func file(
        _ filePattern: String,
        in watchPath: String,
        mode: FileMode = .single,
        includeInCopy: Bool = true,
        removeOriginal: Bool = true,
        instructions: String = "",
        name: String = "Получить файл",
        id: UUID = UUID()
    ) -> SourceStep {
        SourceStep(
            id: id,
            name: name,
            kind: .file(
                instructions: instructions,
                watchPath: watchPath,
                filePattern: filePattern,
                fileMode: mode,
                includeInCopy: includeInCopy,
                removeOriginal: removeOriginal
            )
        )
    }

    public static func device(_ path: String, instructions: String = "", name: String = "Подключить устройство", id: UUID = UUID()) -> SourceStep {
        SourceStep(id: id, name: name, kind: .device(instructions: instructions, path: path))
    }
}

public struct WatchedFile: Sendable, Equatable {
    public let watchPath: String
    public let filePattern: String

    public init(watchPath: String, filePattern: String) {
        self.watchPath = watchPath
        self.filePattern = filePattern
    }
}
