import Foundation

/// A copy of a folder into a work folder that is not what its originals were. The step stops instead of passing it on.
public enum CopyError: Error, Equatable, LocalizedError {
    /// A listed item the copy engine wrote is not in the finished copy.
    case missingFromCopy(String)
    /// An item of the finished copy is of another type, size or link target than its original.
    case changedInCopy(String)
    /// Something is already at a path the copy was to create: copying never writes over anything or through a link.
    case collisionInCopy(String)
    /// A file of the copy is shorter or longer than listed, and its original vanished: the copy holds only part of it.
    case vanishedWhileCopied(String)

    public var errorDescription: String? {
        switch self {
        case let .missingFromCopy(path):
            "“\(path)” was written to the copy but is missing from it now. The copy was stopped so as not to pass for a complete one."
        case let .changedInCopy(path):
            "“\(path)” in the copy is not as its original (another type, size or link target). The copy was stopped so as not to pass for a complete one."
        case let .collisionInCopy(path):
            "“\(path)” already exists in the copy, so nothing was written over it: two originals have names the disk does not tell apart (such as names that differ only in letter case), or something was already there. The copy was stopped so as not to pass for a complete one."
        case let .vanishedWhileCopied(path):
            "The original of “\(path)” vanished while it was being copied, so the copy holds only part of it. The copy was stopped so as not to pass for a complete one."
        }
    }
}
