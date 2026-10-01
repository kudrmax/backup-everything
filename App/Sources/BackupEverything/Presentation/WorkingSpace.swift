import BackupCore
import Foundation

/// Сколько места нужно на ноутбуке, чтобы бэкапы шли. Они идут по одному, поэтому считается не сумма, а самый большой
/// из тех, что собираются во временную папку (папка из одного шага копируется напрямую и места не берёт),
/// плюс пакеты, которые уже ждут записи на отключённый диск.
enum WorkingSpace {
    struct Need: Equatable {
        let bytes: Int64
        let largest: Source?
        let waitingBytes: Int64
    }

    static func need(sources: [Source], lastSizes: [UUID: Int64], waiting: [UUID: Int64]) -> Need {
        let staged = sources.filter { $0.enabled && $0.singleFolder == nil }
        let largest = staged.max { (lastSizes[$0.id] ?? 0) < (lastSizes[$1.id] ?? 0) }
        let largestBytes = largest.flatMap { lastSizes[$0.id] } ?? 0
        let waitingBytes = waiting.filter { $0.key != largest?.id }.values.reduce(0, +)
        return Need(bytes: largestBytes + waitingBytes, largest: largestBytes > 0 ? largest : nil, waitingBytes: waitingBytes)
    }

    static func line(need: Need, free: Int64?) -> String {
        let free = free.map { " · свободно \(Texts.bytes($0))" } ?? ""
        return "Для бэкапов на ноутбуке нужно около \(Texts.bytes(need.bytes)) свободного места\(free)"
    }

    static func details(need: Need) -> String {
        var lines = ["Бэкапы делаются по одному, поэтому место нужно под самый большой из тех, что собираются во временную папку."]
        if let largest = need.largest {
            lines.append("Самый большой — «\(largest.name)».")
        }
        if need.waitingBytes > 0 {
            lines.append("Ещё \(Texts.bytes(need.waitingBytes)) ждут записи на отключённый диск.")
        }
        lines.append("Папки, которые копируются напрямую, временного места не занимают.")
        return lines.joined(separator: "\n")
    }
}
