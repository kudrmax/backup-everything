import BackupCore
import Foundation

enum SourceGuide {
    static func text(for source: Source) -> String {
        var parts = source.instructions.isEmpty ? [] : [source.instructions]
        for (index, step) in source.steps.enumerated() {
            guard let instructions = step.instructions, !instructions.isEmpty else { continue }
            parts.append(source.steps.count > 1 ? "**Шаг \(index + 1). \(step.name)**\n\n\(instructions)" : instructions)
        }
        return parts.joined(separator: "\n\n")
    }
}
