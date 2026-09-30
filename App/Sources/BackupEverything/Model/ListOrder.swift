import Foundation

/// Перестановка при перетаскивании: брошенный элемент встаёт на место того, на который его бросили.
enum ListOrder {
    static func moving(_ id: UUID, onto target: UUID, in ids: [UUID]) -> [UUID]? {
        guard id != target, let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target) else { return nil }
        var result = ids
        result.remove(at: from)
        result.insert(id, at: to)
        return result
    }

    static func movingToEnd(_ id: UUID, in ids: [UUID]) -> [UUID]? {
        guard let from = ids.firstIndex(of: id), from != ids.count - 1 else { return nil }
        var result = ids
        result.remove(at: from)
        result.append(id)
        return result
    }
}
