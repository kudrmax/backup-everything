import Foundation

/// Reordering by drag and drop: the dropped item takes the place of the one it was dropped on.
enum ListOrder {
    static func moving(_ id: UUID, onto target: UUID, in ids: [UUID]) -> [UUID]? {
        guard id != target, let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target) else { return nil }
        var result = ids
        result.remove(at: from)
        result.insert(id, at: to)
        return result
    }

    /// Where the drop line goes: the item takes the place of the one it is dropped on,
    /// so dragged from above it lands below it, and from below it lands above it.
    static func dropsBelow(_ dragged: UUID?, onto target: UUID, in ids: [UUID]) -> Bool {
        guard let dragged, let from = ids.firstIndex(of: dragged), let to = ids.firstIndex(of: target) else { return false }
        return from < to
    }

    static func movingToEnd(_ id: UUID, in ids: [UUID]) -> [UUID]? {
        guard let from = ids.firstIndex(of: id), from != ids.count - 1 else { return nil }
        var result = ids
        result.remove(at: from)
        result.append(id)
        return result
    }
}
