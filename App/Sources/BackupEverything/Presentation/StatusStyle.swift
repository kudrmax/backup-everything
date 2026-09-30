import BackupCore
import SwiftUI

enum StatusStyle {
    static func menuBarSymbol(_ status: OverallStatus, working: Bool) -> String {
        if working { return "arrow.triangle.2.circlepath" }
        switch status {
        case .ok: return "externaldrive.badge.checkmark"
        case .attention: return "externaldrive.badge.exclamationmark"
        case .error: return "externaldrive.badge.xmark"
        }
    }

    static func symbol(_ status: OverallStatus) -> String {
        switch status {
        case .ok: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    static func color(_ status: OverallStatus) -> Color {
        switch status {
        case .ok: .green
        case .attention: .orange
        case .error: .red
        }
    }

    static func symbol(for source: Source) -> String {
        guard source.steps.count == 1 else { return "list.number" }
        return switch source.steps[0].kind {
        case .folder: "folder"
        case .command: "terminal"
        case .file: "square.and.arrow.down"
        case .device: "cable.connector"
        }
    }

    static func symbol(for kind: DestinationKind) -> String {
        switch kind {
        case .localFolder: "externaldrive"
        case .rclone: "cloud"
        }
    }
}
