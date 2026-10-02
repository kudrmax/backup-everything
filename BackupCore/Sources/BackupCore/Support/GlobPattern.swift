import Foundation

/// A shell file-name pattern as `fnmatch` reads it: `*`, `?`, bracket expressions (`[a-z]`, `[!0-9]`) and `\` escapes; case-insensitive.
struct GlobPattern: Sendable {
    private let pattern: String

    init(_ pattern: String) {
        self.pattern = Self.normalize(pattern)
    }

    func matches(_ text: String) -> Bool {
        fnmatch(pattern, Self.normalize(text), 0) == 0
    }

    /// Whether some file name matches both patterns.
    func overlaps(_ other: GlobPattern) -> Bool {
        !Intersection(Atom.parse(pattern), Atom.parse(other.pattern)).isEmpty
    }

    private static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }
}

private enum Atom: Equatable {
    case star
    case one(ScalarSet)

    static func parse(_ pattern: String) -> [Atom] {
        let scalars = Array(pattern.unicodeScalars)
        var atoms: [Atom] = []
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            switch scalar {
            case "*":
                if atoms.last != .star { atoms.append(.star) }
            case "?":
                atoms.append(.one(.any))
            case "[":
                if let (set, end) = bracket(scalars, from: index) {
                    atoms.append(.one(set))
                    index = end
                } else {
                    atoms.append(.one(.only(scalar)))
                }
            case "\\" where index < scalars.count:
                atoms.append(.one(.only(scalars[index])))
                index += 1
            default:
                atoms.append(.one(.only(scalar)))
            }
        }
        return atoms
    }

    /// The bracket expression that starts after `[` at `start`, and the index after its `]`; `nil` when it is not closed.
    private static func bracket(_ scalars: [Unicode.Scalar], from start: Int) -> (ScalarSet, Int)? {
        var index = start
        let negated = index < scalars.count && (scalars[index] == "!" || scalars[index] == "^")
        if negated { index += 1 }
        var ranges: [ClosedRange<UInt32>] = []
        var isFirst = true
        while index < scalars.count {
            var low = scalars[index]
            if low == "]", !isFirst { return (ScalarSet(ranges: ranges, negated: negated), index + 1) }
            isFirst = false
            index += 1
            if low == "\\", index < scalars.count {
                low = scalars[index]
                index += 1
            }
            var high = low
            if index + 1 < scalars.count, scalars[index] == "-", scalars[index + 1] != "]" {
                high = scalars[index + 1]
                index += 2
                if high == "\\", index < scalars.count {
                    high = scalars[index]
                    index += 1
                }
            }
            if low.value <= high.value { ranges.append(low.value ... high.value) }
        }
        return nil
    }
}

/// A set of characters: the listed ranges, or everything except them.
private struct ScalarSet: Equatable {
    let ranges: [ClosedRange<UInt32>]
    let negated: Bool

    init(ranges: [ClosedRange<UInt32>], negated: Bool) {
        self.ranges = ranges
        self.negated = negated
    }

    static let any = ScalarSet(ranges: [], negated: true)

    static func only(_ scalar: Unicode.Scalar) -> ScalarSet {
        ScalarSet(ranges: [scalar.value ... scalar.value], negated: false)
    }

    func intersects(_ other: ScalarSet) -> Bool {
        switch (negated, other.negated) {
        case (true, true):
            true
        case (false, false):
            ranges.contains { mine in other.ranges.contains { mine.overlaps($0) } }
        case (false, true):
            ranges.contains { !$0.isCovered(by: other.ranges) }
        case (true, false):
            other.intersects(self)
        }
    }
}

private extension ClosedRange<UInt32> {
    func isCovered(by ranges: [ClosedRange<UInt32>]) -> Bool {
        var next = lowerBound
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.lowerBound <= next && range.upperBound >= next {
            guard range.upperBound < upperBound else { return true }
            next = range.upperBound + 1
        }
        return false
    }
}

/// Whether two sequences of atoms have a common match, searched over positions in both with memoisation.
private struct Intersection {
    private let first: [Atom]
    private let second: [Atom]

    init(_ first: [Atom], _ second: [Atom]) {
        self.first = first
        self.second = second
    }

    var isEmpty: Bool {
        var memo: [Int: Bool] = [:]
        return !meet(0, 0, &memo)
    }

    private func meet(_ i: Int, _ j: Int, _ memo: inout [Int: Bool]) -> Bool {
        let key = i * (second.count + 1) + j
        if let known = memo[key] { return known }
        let result = switch (first.indices.contains(i) ? first[i] : nil, second.indices.contains(j) ? second[j] : nil) {
        case (.star?, _):
            meet(i + 1, j, &memo) || (j < second.count && meet(i, j + 1, &memo))
        case (_, .star?):
            meet(i, j + 1, &memo) || (i < first.count && meet(i + 1, j, &memo))
        case let (.one(mine)?, .one(theirs)?):
            mine.intersects(theirs) && meet(i + 1, j + 1, &memo)
        case (nil, nil):
            true
        default:
            false
        }
        memo[key] = result
        return result
    }
}
