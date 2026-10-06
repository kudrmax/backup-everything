import BackupCore
import Foundation

enum LiveReport {
    /// What is queued or running is judged when it is done: its old problems neither show nor count, and its copies are
    /// not demanded meanwhile.
    static func of(_ report: StatusReport, running: Set<UUID>) -> StatusReport {
        report.excludingSources(running)
    }
}
