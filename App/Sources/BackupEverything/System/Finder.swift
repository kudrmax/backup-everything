import AppKit

@MainActor
protocol FileRevealing {
    func open(_ url: URL)
    func select(_ url: URL)
}

struct WorkspaceFinder: FileRevealing {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func select(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
