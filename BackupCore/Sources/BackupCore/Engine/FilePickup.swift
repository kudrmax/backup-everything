import Foundation

/// Takes the files of a “Get a file from you” step into the run: all of them or none. What it takes is written down first,
/// next to the chain's folders, and stays there until the chain moves past the step. If the app dies before the step is
/// recorded as done, the next attempt puts every file back where it was taken from: a moved file is the person's only copy.
struct FilePickup: Sendable {
    private struct Entry: Codable {
        let original: String
        let taken: String
        let moved: Bool
    }

    private struct Record: Codable {
        let stepId: UUID
        let entries: [Entry]
    }

    private let file: URL
    private let trash: ManualExportInbox.Trash

    init(folders: WorkFolders, trash: @escaping ManualExportInbox.Trash) {
        file = folders.root.appendingPathComponent("pickup.json")
        self.trash = trash
    }

    func take(_ files: [URL], into directory: URL, keepOriginals: Bool, step: UUID) throws {
        let entries = files.map {
            Entry(original: $0.path, taken: directory.appendingPathComponent($0.lastPathComponent).path, moved: !keepOriginals)
        }
        try JSONEncoder().encode(Record(stepId: step, entries: entries)).write(to: file, options: .atomic)
        let fileManager = FileManager.default
        var taken: [Entry] = []
        do {
            for entry in entries {
                if entry.moved {
                    try fileManager.moveItem(atPath: entry.original, toPath: entry.taken)
                } else {
                    try fileManager.copyItem(atPath: entry.original, toPath: entry.taken)
                }
                taken.append(entry)
            }
        } catch {
            for entry in taken.reversed() {
                if entry.moved {
                    try? fileManager.moveItem(atPath: entry.taken, toPath: entry.original)
                } else {
                    try? fileManager.removeItem(atPath: entry.taken)
                }
            }
            forget()
            throw error
        }
    }

    /// An attempt of `step` that the chain never recorded as done is undone: moved files go back, copies go to the Trash.
    /// A file whose name was taken meanwhile (the person downloaded it again) goes back next to it under a free name,
    /// “name 2.ext”, as Finder names a second copy. A record left by a step the chain has already passed is forgotten.
    func undoUnfinished(of step: UUID?) throws {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let record = try? JSONDecoder().decode(Record.self, from: data), record.stepId == step else {
            forget()
            return
        }
        let fileManager = FileManager.default
        for entry in record.entries.reversed() where fileManager.fileExists(atPath: entry.taken) {
            if entry.moved {
                try fileManager.moveItem(atPath: entry.taken, toPath: freePath(for: entry.original))
            } else {
                try trash(URL(fileURLWithPath: entry.taken))
            }
        }
        forget()
    }

    private func freePath(for path: String) -> String {
        let original = path as NSString
        let folder = original.deletingLastPathComponent as NSString
        let base = (original.lastPathComponent as NSString).deletingPathExtension
        let suffix = original.pathExtension.isEmpty ? "" : "." + original.pathExtension
        var candidate = path
        var number = 2
        while FileManager.default.fileExists(atPath: candidate) {
            candidate = folder.appendingPathComponent("\(base) \(number)\(suffix)")
            number += 1
        }
        return candidate
    }

    private func forget() {
        try? FileManager.default.removeItem(at: file)
    }
}
