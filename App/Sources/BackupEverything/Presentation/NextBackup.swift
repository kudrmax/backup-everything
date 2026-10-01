import BackupCore
import Foundation

enum NextBackup {
    static func note(_ source: Source, nextDue: Date?, isWaiting: Bool, now: Date = Date()) -> String? {
        guard source.enabled else { return nil }
        if isWaiting { return "waiting" }
        guard let nextDue else { return "manual" }
        return nextDue <= now ? "due" : Texts.until(nextDue, now: now)
    }

    static func detail(_ source: Source, nextDue: Date?, isWaiting: Bool, now: Date = Date()) -> String {
        guard source.enabled else { return "source is disabled" }
        if isWaiting { return "waiting for a file or device — starts on its own" }
        guard let nextDue else { return "only with the “Run” button" }
        return nextDue <= now ? "due now" : Texts.dateTime(nextDue)
    }
}
