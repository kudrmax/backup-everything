import Foundation

public struct ManualExportSource: SourceProvider {
    private let sourceId: UUID
    private let removeOriginal: Bool
    private let inbox: ManualExportInbox

    public init(sourceId: UUID, removeOriginal: Bool, inbox: ManualExportInbox) {
        self.sourceId = sourceId
        self.removeOriginal = removeOriginal
        self.inbox = inbox
    }

    public func collect(at date: Date, status: @escaping StatusHandler) async throws -> Payload {
        guard let package = inbox.pendingPackage(for: sourceId) else {
            throw SourceError.nothingToCollect
        }
        return Payload(root: package.directory, collectedAt: package.collectedAt)
    }

    public func finish(_ payload: Payload, deliveredEverywhere: Bool) {
        guard deliveredEverywhere else { return }
        try? inbox.removePackage(for: sourceId, toTrash: removeOriginal)
    }
}
