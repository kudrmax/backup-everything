import Foundation

/// Результат, собранный с участием человека: лежит в pending, пока не доставлен во все назначения.
public struct PendingSource: SourceProvider {
    private let sourceId: UUID
    private let trashAfterDelivery: Bool
    private let inbox: ManualExportInbox

    public init(sourceId: UUID, trashAfterDelivery: Bool, inbox: ManualExportInbox) {
        self.sourceId = sourceId
        self.trashAfterDelivery = trashAfterDelivery
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
        try? inbox.removePackage(for: sourceId, toTrash: trashAfterDelivery)
    }
}
