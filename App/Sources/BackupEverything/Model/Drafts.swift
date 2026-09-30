import BackupCore
import Foundation

enum SourceKindChoice: String, CaseIterable, Identifiable {
    case folder
    case command
    case manualExport
    case steps
    case device

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folder: "Папка"
        case .command: "Команда"
        case .manualExport: "Ручной экспорт"
        case .steps: "По шагам"
        case .device: "Подключаемое устройство"
        }
    }
}

enum StepKindChoice: String, CaseIterable, Identifiable {
    case manual
    case command

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "Ручной шаг"
        case .command: "Команда"
        }
    }
}

struct StepDraft: Identifiable, Equatable {
    var id: UUID
    var name: String
    var kindChoice: StepKindChoice
    var instructions = ""
    var watchPath = "~/Downloads"
    var filePattern = ""
    var includeInCopy = true
    var command = ""
    var timeoutMinutes = 60

    init(new kindChoice: StepKindChoice) {
        id = UUID()
        name = kindChoice.title
        self.kindChoice = kindChoice
    }

    init(_ step: SourceStep) {
        id = step.id
        name = step.name
        switch step.kind {
        case let .manual(instructions, watchPath, filePattern, includeInCopy):
            kindChoice = .manual
            self.instructions = instructions
            self.watchPath = watchPath
            self.filePattern = filePattern
            self.includeInCopy = includeInCopy
        case let .command(command, timeoutSeconds):
            kindChoice = .command
            self.command = command
            timeoutMinutes = max(1, timeoutSeconds / 60)
        }
    }

    var problem: String? {
        if trimmed(name).isEmpty { return "укажите название." }
        switch kindChoice {
        case .manual where trimmed(watchPath).isEmpty: return "укажите папку, куда попадает файл."
        case .manual where trimmed(filePattern).isEmpty: return "укажите маску файла, например manifest-*.json."
        case .command where trimmed(command).isEmpty: return "укажите команду."
        default: return nil
        }
    }

    func build() -> SourceStep {
        let kind: StepKind = switch kindChoice {
        case .manual:
            .manual(instructions: instructions, watchPath: trimmed(watchPath), filePattern: trimmed(filePattern), includeInCopy: includeInCopy)
        case .command:
            .command(command: command, timeoutSeconds: max(1, timeoutMinutes) * 60)
        }
        return SourceStep(id: id, name: trimmed(name), kind: kind)
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SourceDraft {
    private var base: Source

    var name: String
    var schedule: Schedule
    var retention: RetentionRules
    var destinationIds: Set<UUID>
    var description: String
    var instructions: String
    var icon: String?
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
    var steps: [StepDraft] = []

    init(_ source: Source) {
        base = source
        name = source.name
        schedule = source.schedule
        retention = source.retention
        destinationIds = Set(source.destinationIds)
        description = source.description
        instructions = source.instructions
        icon = source.icon
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
        case let .steps(steps):
            kindChoice = .steps
            self.steps = steps.map(StepDraft.init)
        case let .device(path, excludes):
            kindChoice = .device
            folderPath = path
            excludesText = excludes.joined(separator: "\n")
        }
    }

    var id: UUID { base.id }

    var problem: String? {
        kindProblem ?? (trimmed(name).isEmpty ? "Укажите название." : nil)
    }

    private var kindProblem: String? {
        switch kindChoice {
        case .folder:
            return trimmed(folderPath).isEmpty ? "Укажите папку или файл источника." : nil
        case .device:
            return trimmed(folderPath).isEmpty ? "Укажите папку на устройстве." : nil
        case .command:
            return trimmed(command).isEmpty ? "Укажите команду." : nil
        case .manualExport:
            if trimmed(watchPath).isEmpty { return "Укажите папку, куда попадает экспорт." }
            return trimmed(filePattern).isEmpty ? "Укажите маску файла, например Passwords*.csv." : nil
        case .steps:
            if steps.isEmpty { return "Добавьте хотя бы один шаг." }
            for (index, step) in steps.enumerated() {
                if let problem = step.problem { return "Шаг \(index + 1): \(problem)" }
            }
            return nil
        }
    }

    var firstStepIsManual: Bool {
        kindChoice == .steps && steps.first?.kindChoice == .manual
    }

    var hasChanges: Bool { build() != base }

    func build() -> Source {
        var source = base
        source.name = trimmed(name)
        source.schedule = schedule
        source.retention = retention
        source.destinationIds = base.destinationIds.filter(destinationIds.contains)
            + destinationIds.subtracting(base.destinationIds).sorted { $0.uuidString < $1.uuidString }
        source.description = trimmed(description)
        source.instructions = instructions
        source.icon = icon
        source.enabled = enabled
        switch kindChoice {
        case .folder:
            source.kind = .folder(path: trimmed(folderPath), excludes: excludes)
        case .device:
            source.kind = .device(path: trimmed(folderPath), excludes: excludes)
        case .command:
            source.kind = .command(command: command, timeoutSeconds: max(1, timeoutMinutes) * 60)
        case .manualExport:
            source.kind = .manualExport(
                watchPath: trimmed(watchPath),
                filePattern: trimmed(filePattern),
                fileMode: fileMode,
                removeOriginal: removeOriginal
            )
        case .steps:
            source.kind = .steps(steps: steps.map { $0.build() })
        }
        return source
    }

    private var excludes: [String] {
        excludesText.split(separator: "\n").map { trimmed(String($0)) }.filter { !$0.isEmpty }
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

    var hasChanges: Bool { build() != base }

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
