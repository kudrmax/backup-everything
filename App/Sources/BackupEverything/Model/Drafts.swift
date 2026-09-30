import BackupCore
import Foundation

enum StepKindChoice: String, CaseIterable, Identifiable {
    case folder
    case command
    case file
    case device

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folder: "Скопировать папку"
        case .command: "Выполнить команду"
        case .file: "Получить файл от тебя"
        case .device: "Подключить устройство"
        }
    }

    var symbol: String {
        switch self {
        case .folder: "folder"
        case .command: "terminal"
        case .file: "square.and.arrow.down"
        case .device: "cable.connector"
        }
    }
}

/// С чего начать пустой источник. «Папка на устройстве» сразу даёт два шага.
enum SourceStart: String, CaseIterable, Identifiable {
    case folder
    case command
    case file
    case device

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folder: "Папка"
        case .command: "Команда"
        case .file: "Файл, который выгружаешь сам"
        case .device: "Папка на подключаемом устройстве"
        }
    }

    var steps: [StepDraft] {
        switch self {
        case .folder: [StepDraft(new: .folder)]
        case .command: [StepDraft(new: .command)]
        case .file: [StepDraft(new: .file)]
        case .device: [StepDraft(new: .device), StepDraft(new: .folder)]
        }
    }
}

struct StepDraft: Identifiable, Equatable {
    var id: UUID
    var name: String
    var kindChoice: StepKindChoice
    var folderPath = ""
    var excludesText = ""
    var command = ""
    var timeoutMinutes = 60
    var instructions = ""
    var watchPath = "~/Downloads"
    var filePattern = ""
    var fileMode = FileMode.single
    var includeInCopy = true
    var removeOriginal = true
    var devicePath = ""

    init(new kindChoice: StepKindChoice) {
        id = UUID()
        name = kindChoice.title
        self.kindChoice = kindChoice
    }

    init(_ step: SourceStep) {
        id = step.id
        name = step.name
        switch step.kind {
        case let .folder(path, excludes):
            kindChoice = .folder
            folderPath = path
            excludesText = excludes.joined(separator: "\n")
        case let .command(command, timeoutSeconds):
            kindChoice = .command
            self.command = command
            timeoutMinutes = max(1, timeoutSeconds / 60)
        case let .file(instructions, watchPath, filePattern, fileMode, includeInCopy, removeOriginal):
            kindChoice = .file
            self.instructions = instructions
            self.watchPath = watchPath
            self.filePattern = filePattern
            self.fileMode = fileMode
            self.includeInCopy = includeInCopy
            self.removeOriginal = removeOriginal
        case let .device(instructions, path):
            kindChoice = .device
            self.instructions = instructions
            devicePath = path
        }
    }

    func problem(followedByFolder: Bool) -> String? {
        if trimmed(name).isEmpty { return "укажите название." }
        switch kindChoice {
        case .folder where trimmed(folderPath).isEmpty: return "укажите папку или файл."
        case .command where trimmed(command).isEmpty: return "укажите команду."
        case .file where trimmed(watchPath).isEmpty: return "укажите папку, куда попадает файл."
        case .file where trimmed(filePattern).isEmpty: return "укажите маску файла, например manifest-*.json."
        case .device where trimmed(devicePath).isEmpty && !followedByFolder: return "укажите путь на устройстве."
        default: return nil
        }
    }

    var excludes: [String] {
        excludesText.split(separator: "\n").map { trimmed(String($0)) }.filter { !$0.isEmpty }
    }

    func build() -> SourceStep {
        let kind: StepKind = switch kindChoice {
        case .folder:
            .folder(path: trimmed(folderPath), excludes: excludes)
        case .command:
            .command(command: command, timeoutSeconds: max(1, timeoutMinutes) * 60)
        case .file:
            .file(
                instructions: instructions,
                watchPath: trimmed(watchPath),
                filePattern: trimmed(filePattern),
                fileMode: fileMode,
                includeInCopy: includeInCopy,
                removeOriginal: removeOriginal
            )
        case .device:
            .device(instructions: instructions, path: trimmed(devicePath))
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
    var steps: [StepDraft]

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
        steps = source.steps.map(StepDraft.init)
    }

    var id: UUID { base.id }

    var problem: String? {
        if steps.isEmpty { return "Добавьте хотя бы один шаг." }
        for (index, step) in steps.enumerated() {
            let followedByFolder = steps[(index + 1)...].contains { $0.kindChoice == .folder }
            if let problem = step.problem(followedByFolder: followedByFolder) {
                return steps.count == 1 ? problem.prefix(1).uppercased() + problem.dropFirst() : "Шаг \(index + 1): \(problem)"
            }
        }
        return trimmed(name).isEmpty ? "Укажите название." : nil
    }

    var hasChanges: Bool { build() != base }

    var symbol: String {
        steps.count == 1 ? steps[0].kindChoice.symbol : "list.number"
    }

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
        source.steps = steps.map { $0.build() }
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
