import Foundation

/// A result gathered with manual steps: it stays in pending until it is delivered to every destination. A delivery that
/// ends while the app is quitting is not recorded, so its debts stay open: the package stays for the next launch to deliver.
public struct PendingSource: SourceProvider {
    private let sourceId: UUID
    private let trashAfterDelivery: Bool
    private let inbox: ManualExportInbox
    private let quit: any QuitSignal

    public init(sourceId: UUID, trashAfterDelivery: Bool, inbox: ManualExportInbox, quit: any QuitSignal = ProcessGroups.shared) {
        self.sourceId = sourceId
        self.trashAfterDelivery = trashAfterDelivery
        self.inbox = inbox
        self.quit = quit
    }

    public func collect(at date: Date, status: @escaping StatusHandler) async throws -> Payload {
        guard let package = inbox.pendingPackage(for: sourceId) else {
            throw SourceError.nothingToCollect
        }
        return Payload(root: package.directory, collectedAt: package.collectedAt, madeEarlier: true)
    }

    public func finish(_ payload: Payload, deliveredEverywhere: Bool) throws {
        guard deliveredEverywhere, !quit.isQuitting else { return }
        try inbox.removePackage(for: sourceId, toTrash: trashAfterDelivery)
    }
}
