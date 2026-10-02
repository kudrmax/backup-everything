import Foundation

struct TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func path(_ relative: String) -> URL {
        url.appendingPathComponent(relative)
    }

    @discardableResult
    func directory(_ relative: String) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    @discardableResult
    func file(_ relative: String, _ content: String = "content", modified: Date? = nil) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: target)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified, .creationDate: modified], ofItemAtPath: target.path)
        }
        return target
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: path(relative).path)
    }

    func allocatedBytes(_ relatives: String...) throws -> Int64 {
        try relatives.reduce(0) { total, relative in
            total + Int64(try path(relative).resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0)
        }
    }

    func names(in relative: String = "") -> [String] {
        let target = relative.isEmpty ? url : path(relative)
        return ((try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []).sorted()
    }
}
