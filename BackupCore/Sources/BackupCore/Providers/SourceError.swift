import Foundation

public enum SourceError: Error, Equatable, LocalizedError {
    case pathMissing(String)
    case commandFailed(exitCode: Int32, output: String)
    case commandTimedOut(seconds: Int, output: String)
    case commandStopped(signal: Int32, output: String)
    case emptyResult
    case nothingToCollect
    case stepFailed(index: Int, count: Int, name: String, reason: String)
    case pickupFailed(String)
    case unreadable(String)
    case reservedName(String)
    case leftoversRemain(reason: String, cleanup: String)

    public var errorDescription: String? {
        switch self {
        case let .pathMissing(path):
            "Source path not found: \(path)"
        case let .commandFailed(exitCode, output):
            "Command exited with code \(exitCode). \(output)"
        case let .commandTimedOut(seconds, output):
            "Command did not finish within \(seconds) s and was stopped. \(output)"
        case let .commandStopped(signal, output):
            "Command was stopped by a signal (\(String(cString: strsignal(signal)))). \(output)"
        case .emptyResult:
            "The source produced no files. An empty copy is not created."
        case .nothingToCollect:
            "No picked-up files for this source."
        case let .pickupFailed(reason):
            "Could not pick up the files: \(reason)"
        case let .unreadable(path):
            "Could not read “\(path)”, so the copy would miss it. Give Backup Everything access (System Settings → Privacy & Security → Full Disk Access) or add it to the exclusions."
        case let .reservedName(name):
            "“\(name)” at the top of the source has the name Backup Everything gives its own file in every copy. Rename it, move it into a subfolder or add it to the exclusions."
        case let .leftoversRemain(reason, cleanup):
            "\(reason) What the step had added could not be moved to the Trash: \(cleanup)"
        case let .stepFailed(index, count, name, reason):
            "Step \(index + 1) of \(count) “\(name)”. \(reason)"
        }
    }
}
