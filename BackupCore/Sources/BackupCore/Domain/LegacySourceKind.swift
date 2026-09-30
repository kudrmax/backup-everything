import Foundation

/// Тип источника из конфигов до перехода на шаги. Только читается и сразу превращается в шаги.
enum LegacySourceKind: Decodable {
    case folder(path: String, excludes: [String])
    case command(command: String, timeoutSeconds: Int)
    case manualExport(watchPath: String, filePattern: String, fileMode: FileMode, removeOriginal: Bool)
    case steps(steps: [SourceStep])
    case device(path: String, excludes: [String])

    /// Шаги и то, что остаётся общей инструкцией источника: у ручных типов она переезжает в шаг человека.
    func converted(owner: UUID, instructions: String) -> (steps: [SourceStep], instructions: String) {
        switch self {
        case let .folder(path, excludes):
            return ([.folder(path, excludes: excludes, id: Self.stepId(owner, 0))], instructions)
        case let .command(command, timeoutSeconds):
            return ([.command(command, timeoutSeconds: timeoutSeconds, id: Self.stepId(owner, 0))], instructions)
        case let .manualExport(watchPath, filePattern, fileMode, removeOriginal):
            let step = SourceStep.file(
                filePattern,
                in: watchPath,
                mode: fileMode,
                removeOriginal: removeOriginal,
                instructions: instructions,
                name: "Выгрузить файл",
                id: Self.stepId(owner, 0)
            )
            return ([step], "")
        case let .steps(steps):
            return (steps, instructions)
        case let .device(path, excludes):
            return (
                [
                    .device(path, instructions: instructions, id: Self.stepId(owner, 0)),
                    .folder(path, excludes: excludes, id: Self.stepId(owner, 1)),
                ],
                ""
            )
        }
    }

    /// Постоянный id шага, выведенный из id источника: при каждом чтении старого конфига шаги узнаются как те же.
    static func stepId(_ owner: UUID, _ index: Int) -> UUID {
        var bytes = owner.uuid
        bytes.14 ^= 0x5A
        bytes.15 = bytes.15 &+ UInt8(index + 1)
        return UUID(uuid: bytes)
    }
}
