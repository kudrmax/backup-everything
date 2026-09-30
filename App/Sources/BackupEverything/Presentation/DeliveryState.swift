import BackupCore

enum DeliveryState: Equatable {
    case delivered
    case failed
    case waiting
    case none

    static func of(lastOutcome: DeliveryOutcome?, isWaiting: Bool) -> DeliveryState {
        switch lastOutcome {
        case .failed where isWaiting: .failed
        case _ where isWaiting: .waiting
        case .delivered: .delivered
        default: .none
        }
    }
}
