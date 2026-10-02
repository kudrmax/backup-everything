import Foundation

/// Working folders of one run: files from the person for commands, the future copy and a draft.
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

    /// What lies in the input and output folders goes to the Trash: a command may have moved a person's originals there.
    /// The rest (the draft folder, the record of the running command) is deleted. `trash` must cope with locked items.
    func discard(using trash: ManualExportInbox.Trash) throws {
        let fileManager = FileManager.default
        for directory in [input, output] {
            for item in (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                try trash(item)
            }
        }
        if fileManager.fileExists(atPath: root.path) {
            try FolderRemoval().remove(root.path)
        }
    }

    var environment: [String: String] {
        ["BACKUP_INPUT_DIR": input.path, "BACKUP_OUTPUT_DIR": output.path, "BACKUP_SCRATCH_DIR": scratch.path]
    }
}
