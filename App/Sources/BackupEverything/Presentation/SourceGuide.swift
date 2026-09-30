import BackupCore
import Foundation

enum SourceGuide {
    static func text(for source: Source) -> String {
        var parts = source.instructions.isEmpty ? [] : [source.instructions]
        for (index, step) in source.steps.enumerated() {
            guard case let .manual(instructions, _, _, _) = step.kind, !instructions.isEmpty else { continue }
            parts.append("**Шаг \(index + 1). \(step.name)**\n\n\(instructions)")
        }
        return parts.joined(separator: "\n\n")
    }
}
