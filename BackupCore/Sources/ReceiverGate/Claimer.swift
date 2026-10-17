import Darwin
import Foundation

/// Creates the target of a plan before rsync starts. Creation fails when the target is already there, so a folder
/// or a marker is written by one gate only, even when two run at once.
public enum Claimer {
    private static let folderMode: mode_t = 0o750
    private static let markerMode: mode_t = 0o640

    public static func claim(_ claim: Claim) -> GateError? {
        switch claim {
        case let .folder(folder): claimFolder(folder)
        case let .marker(marker): claimMarker(marker)
        }
    }

    /// Missing parents are created like rsync `--mkpath` would; only the final folder must be new.
    private static func claimFolder(_ folder: String) -> GateError? {
        var missing: [String] = []
        var current = (folder as NSString).deletingLastPathComponent
        var info = stat()
        while current != "/", lstat(current, &info) != 0 {
            missing.insert(current, at: 0)
            current = (current as NSString).deletingLastPathComponent
        }
        for parent in missing where mkdir(parent, folderMode) != 0 && errno != EEXIST {
            return failure("cannot create \(parent)")
        }
        guard mkdir(folder, folderMode) == 0 else {
            return errno == EEXIST ? GateError(message: "\(folder) already exists") : failure("cannot create \(folder)")
        }
        return nil
    }

    private static func claimMarker(_ marker: String) -> GateError? {
        let descriptor = open(marker, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, markerMode)
        guard descriptor >= 0 else {
            return errno == EEXIST ? GateError(message: "\(marker) is a finished copy") : failure("cannot create \(marker)")
        }
        close(descriptor)
        return nil
    }

    private static func failure(_ message: String) -> GateError {
        GateError(message: "\(message): \(String(cString: strerror(errno)))")
    }
}
