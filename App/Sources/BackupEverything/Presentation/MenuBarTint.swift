import AppKit
import BackupCore

enum MenuBarTint: Equatable {
    case standard
    case attention
    case error

    static func of(_ status: OverallStatus) -> MenuBarTint {
        switch status {
        case .ok: .standard
        case .attention: .attention
        case .error: .error
        }
    }

    var color: NSColor? {
        switch self {
        case .standard: nil
        case .attention: .systemYellow
        case .error: .systemRed
        }
    }
}
