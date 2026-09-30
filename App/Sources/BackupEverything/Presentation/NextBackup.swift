import BackupCore
import Foundation

enum NextBackup {
    static func note(_ source: Source, nextDue: Date?, isWaiting: Bool, now: Date = Date()) -> String? {
        guard source.enabled else { return nil }
        if isWaiting { return "ждёт" }
        guard let nextDue else { return "по кнопке" }
        return nextDue <= now ? "пора" : Texts.until(nextDue, now: now)
    }

    static func detail(_ source: Source, nextDue: Date?, isWaiting: Bool, now: Date = Date()) -> String {
        guard source.enabled else { return "источник выключен" }
        if isWaiting { return "ждёт файл или устройство — начнётся сам" }
        guard let nextDue else { return "только по кнопке «Запустить»" }
        return nextDue <= now ? "уже пора" : Texts.dateTime(nextDue)
    }
}
