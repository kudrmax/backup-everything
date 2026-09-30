import Foundation

/// Рабочие папки одного запуска: файлы от человека для команд, будущая копия и черновик.
struct WorkFolders {
    let root: URL

    var input: URL { root.appendingPathComponent("input", isDirectory: true) }
    var output: URL { root.appendingPathComponent("output", isDirectory: true) }
    var scratch: URL { root.appendingPathComponent("scratch", isDirectory: true) }

    func prepare() throws {
        for directory in [input, output, scratch] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    var environment: [String: String] {
        ["BACKUP_INPUT_DIR": input.path, "BACKUP_OUTPUT_DIR": output.path, "BACKUP_SCRATCH_DIR": scratch.path]
    }
}
