import Foundation

public enum SourceError: Error, Equatable, LocalizedError {
    case pathMissing(String)
    case commandFailed(exitCode: Int32, output: String)
    case commandTimedOut(seconds: Int, output: String)
    case emptyResult
    case nothingToCollect

    public var errorDescription: String? {
        switch self {
        case let .pathMissing(path):
            "Не найден путь источника: \(path)"
        case let .commandFailed(exitCode, output):
            "Команда завершилась с кодом \(exitCode). \(output)"
        case let .commandTimedOut(seconds, output):
            "Команда не уложилась в \(seconds) с и была остановлена. \(output)"
        case .emptyResult:
            "Источник не дал ни одного файла. Пустая копия не создаётся."
        case .nothingToCollect:
            "Нет подхваченных файлов для этого источника."
        }
    }
}
