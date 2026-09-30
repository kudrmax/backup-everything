import BackupCore
import Foundation

enum ChainPosition {
    static func label(index: Int, count: Int) -> String {
        "шаг \(index + 1) из \(count)"
    }

    static func label(of source: Source, chain: ChainState?) -> String? {
        let count = source.steps.count
        guard count > 0 else { return nil }
        return label(index: min(chain?.stepIndex ?? 0, count - 1), count: count)
    }

    static func note(_ note: String?, of source: Source, chain: ChainState?) -> String? {
        guard let note else { return nil }
        guard let label = label(of: source, chain: chain) else { return note }
        return "\(label) · \(note)"
    }
}
