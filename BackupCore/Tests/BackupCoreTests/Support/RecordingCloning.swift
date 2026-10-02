import Foundation
@testable import BackupCore

final class RecordingCloning: FileCloning, @unchecked Sendable {
    enum Mode {
        case real
        case unsupported
        case failing
        /// The clone comes out shorter than its original.
        case truncating
    }

    private let mode: Mode
    private let lock = NSLock()
    private var recorded: [(original: URL, target: URL)] = []

    init(_ mode: Mode = .real) {
        self.mode = mode
    }

    var clones: [(original: URL, target: URL)] {
        lock.withLock { recorded }
    }

    func clonedTargets(relativeTo snapshotDirectory: URL) -> [String] {
        clones.map { String($0.target.path.dropFirst(snapshotDirectory.path.count + 1)) }.sorted()
    }

    func isSupported(at folder: URL) -> Bool {
        mode != .unsupported && APFSCloning().isSupported(at: folder)
    }

    func clone(_ original: URL, to targetPath: String) throws {
        if mode == .failing { throw POSIXError(.ENOTSUP) }
        try APFSCloning().clone(original, to: targetPath)
        if mode == .truncating { truncate(targetPath, 1) }
        lock.withLock { recorded.append((original, URL(fileURLWithPath: targetPath))) }
    }
}
