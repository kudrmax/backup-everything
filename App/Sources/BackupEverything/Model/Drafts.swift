import BackupCore
import Foundation

enum SourceKindChoice: String, CaseIterable, Identifiable {
    case folder
    case command
    case manualExport

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folder: "Папка"
        case .command: "Команда"
        case .manualExport: "Ручной экспорт"
        }
    }
}

struct SourceDraft {
    private var base: Source

    var name: String
    var schedule: Schedule
    var retention: RetentionRules
    var destinationIds: Set<UUID>
    var instructions: String
    var enabled: Bool
    var kindChoice: SourceKindChoice

    var folderPath = ""
    var excludesText = ""
    var command = ""
    var timeoutMinutes = 60
    var watchPath = "~/Downloads"
    var filePattern = ""
    var fileMode = FileMode.single
    var removeOriginal = true

    init(_ source: Source) {
        base = source
        name = source.name
        schedule = source.schedule
        retention = source.retention
        destinationIds = Set(source.destinationIds)
        instructions = source.instructions
        enabled = source.enabled
        switch source.kind {
        case let .folder(path, excludes):
            kindChoice = .folder
            folderPath = path
            excludesText = excludes.joined(separator: "\n")
        case let .command(command, timeoutSeconds):
            kindChoice = .command
            self.command = command
            timeoutMinutes = max(1, timeoutSeconds / 60)
        case let .manualExport(watchPath, filePattern, fileMode, removeOriginal):
            kindChoice = .manualExport
            self.watchPath = watchPath
            self.filePattern = filePattern
            self.fileMode = fileMode
            self.removeOriginal = removeOriginal
        }
    }

    var id: UUID { base.id }

    var problem: String? {
        switch kindChoice {
        case .folder where trimmed(folderPath).isEmpty: return "Укажите папку или файл источника."
        case .command where trimmed(command).isEmpty: return "Укажите команду."
        case .manualExport where trimmed(watchPath).isEmpty: return "Укажите папку, куда попадает экспорт."
        case .manualExport where trimmed(filePattern).isEmpty: return "Укажите маску файла, например Passwords*.csv."
        default: break
        }
        return trimmed(name).isEmpty ? "Укажите название." : nil
    }

    func build() -> Source {
        var source = base
        source.name = trimmed(name)
        source.schedule = schedule
        source.retention = retention
        source.destinationIds = base.destinationIds.filter(destinationIds.contains)
            + destinationIds.subtracting(base.destinationIds).sorted { $0.uuidString < $1.uuidString }
        source.instructions = instructions
        source.enabled = enabled
        switch kindChoice {
        case .folder:
            let excludes = excludesText.split(separator: "\n").map { trimmed(String($0)) }.filter { !$0.isEmpty }
            source.kind = .folder(path: trimmed(folderPath), excludes: excludes)
        case .command:
            source.kind = .command(command: command, timeoutSeconds: max(1, timeoutMinutes) * 60)
        case .manualExport:
            source.kind = .manualExport(
                watchPath: trimmed(watchPath),
                filePattern: trimmed(filePattern),
                fileMode: fileMode,
                removeOriginal: removeOriginal
            )
        }
        return source
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum DestinationTypeChoice: String, CaseIterable, Identifiable {
    case local
    case rclone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: "Папка или диск"
        case .rclone: "Облако (rclone)"
        }
    }
}

struct DestinationDraft {
    private var base: Destination

    var name: String
    var typeChoice: DestinationTypeChoice
    var path = ""
    var remote = ""
    var remotePath = "backups"
    var isPeriodic = false
    var days = 30

    init(_ destination: Destination) {
        base = destination
        name = destination.name
        switch destination.kind {
        case let .localFolder(path):
            typeChoice = .local
            self.path = path
        case let .rclone(remote, path):
            typeChoice = .rclone
            self.remote = remote
            remotePath = path
        }
        if case let .days(days) = destination.expectedEvery {
            isPeriodic = true
            self.days = days
        }
    }

    var id: UUID { base.id }

    var problem: String? {
        if trimmed(name).isEmpty { return "Укажите название." }
        switch typeChoice {
        case .local where trimmed(path).isEmpty: return "Выберите папку."
        case .rclone where trimmed(remote).isEmpty: return "Выберите подключённое облако."
        default: return nil
        }
    }

    func build() -> Destination {
        var destination = base
        destination.name = trimmed(name)
        destination.kind = switch typeChoice {
        case .local: .localFolder(path: trimmed(path))
        case .rclone: .rclone(remote: trimmed(remote), path: trimmed(remotePath))
        }
        destination.expectedEvery = isPeriodic ? .days(max(1, days)) : .always
        return destination
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
