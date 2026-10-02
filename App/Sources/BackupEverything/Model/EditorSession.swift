import BackupCore
import Foundation

protocol EditableDraft {
    associatedtype Item: Identifiable where Item.ID == UUID

    init(_ item: Item)
    var id: UUID { get }
}

extension SourceDraft: EditableDraft {}
extension DestinationDraft: EditableDraft {}

/// What a settings list shows on the right: a saved item being edited or a new one not added yet.
struct EditorSession<Draft: EditableDraft> {
    var selection: UUID?
    var draft: Draft?
    private(set) var isNew = false

    /// The item chosen last time, or the first one if it is gone.
    mutating func appear(remembered: UUID?, in items: [Draft.Item]) {
        let stored = remembered.flatMap { id in items.first { $0.id == id } }
        selection = (stored ?? items.first)?.id
    }

    /// Opens the selected item; returns its id to remember, or nil if there is nothing to open.
    mutating func selectionChanged(to id: UUID?, in items: [Draft.Item]) -> UUID? {
        guard let id, let item = items.first(where: { $0.id == id }) else { return nil }
        draft = Draft(item)
        isNew = false
        return id
    }

    mutating func start(_ draft: Draft) {
        selection = nil
        self.draft = draft
        isNew = true
    }

    mutating func saved(_ item: Draft.Item) {
        isNew = false
        draft = Draft(item)
        selection = item.id
    }

    /// Back to the saved version; a new item is dropped.
    mutating func cancel(in items: [Draft.Item]) {
        if !isNew, let id = draft?.id, let saved = items.first(where: { $0.id == id }) {
            draft = Draft(saved)
        } else {
            showFirst(of: items)
        }
    }

    mutating func showFirst(of items: [Draft.Item]) {
        isNew = false
        draft = items.first.map(Draft.init)
        selection = draft?.id
    }
}
