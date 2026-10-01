import Foundation

/// Тексты о диске «время от времени»: почему его просят подключить и что с пропущенными бэкапами.
enum ConnectReminder {
    static func notice(destinationName: String, onlyCopyOf sources: [String]) -> (title: String, body: String) {
        let title = "Подключи «\(destinationName)»"
        guard !sources.isEmpty else {
            return (title, "Диск давно не подключался. Копии есть на других дисках, но и этот пора обновить.")
        }
        let names = sources.map { "«\($0)»" }.joined(separator: ", ")
        let body = sources.count == 1
            ? "Бэкапа \(names) больше нигде нет — он запишется, как только подключишь диск."
            : "Бэкапов \(names) больше нигде нет — они запишутся, как только подключишь диск."
        return (title, body)
    }

    static func waitingLine(elsewhere: Bool, otherDestinations: [String]) -> String {
        guard elsewhere, !otherDestinations.isEmpty else { return "этого бэкапа больше нигде нет — подключи диск" }
        return "копия есть на " + otherDestinations.map { "«\($0)»" }.joined(separator: ", ")
    }

    static let settingsExplanation = "Пока срок не вышел, напоминаний нет — если пропущенные бэкапы есть на других дисках. Если какого-то бэкапа больше нигде нет, напомню сразу. При подключении диск получит свежую копию каждого источника."
}
