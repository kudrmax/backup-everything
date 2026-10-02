import CoreGraphics

/// A line of a wrapping row: which items it holds and how much room they take.
struct FlowLine: Equatable {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0

    /// Items go left to right and wrap when the next one doesn’t fit; an item wider than the row still gets a line of its own.
    static func lines(sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> [FlowLine] {
        var lines = [FlowLine()]
        for (index, size) in sizes.enumerated() {
            let gap = lines[lines.count - 1].indices.isEmpty ? 0 : spacing
            if lines[lines.count - 1].width + gap + size.width > width, !lines[lines.count - 1].indices.isEmpty {
                lines.append(FlowLine())
            }
            let lead = lines[lines.count - 1].indices.isEmpty ? 0 : spacing
            lines[lines.count - 1].indices.append(index)
            lines[lines.count - 1].width += lead + size.width
            lines[lines.count - 1].height = max(lines[lines.count - 1].height, size.height)
        }
        return lines
    }
}
