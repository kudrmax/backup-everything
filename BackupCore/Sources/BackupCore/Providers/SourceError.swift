import Foundation

public enum SourceError: Error, Equatable, LocalizedError {
    case pathMissing(String)
    case commandFailed(exitCode: Int32, output: String)
    case commandTimedOut(seconds: Int, output: String)
    case emptyResult
    case nothingToCollect
    case stepFailed(index: Int, count: Int, name: String, reason: String)
    case pickupFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .pathMissing(path):
            "Source path not found: \(path)"
        case let .commandFailed(exitCode, output):
            "Command exited with code \(exitCode). \(output)"
        case let .commandTimedOut(seconds, output):
            "Command did not finish within \(seconds) s and was stopped. \(output)"
        case .emptyResult:
            "The source produced no files. An empty copy is not created."
        case .nothingToCollect:
            "No picked-up files for this source."
        case let .pickupFailed(reason):
            "Could not pick up the files: \(reason)"
        case let .stepFailed(index, count, name, reason):
            "Step \(index + 1) of \(count) “\(name)”. \(reason)"
        }
    }
}
