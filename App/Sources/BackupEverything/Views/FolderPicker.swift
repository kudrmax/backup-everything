import AppKit

@MainActor
enum FolderPicker {
    static func choose(allowsFiles: Bool = false) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = allowsFiles
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }
}
