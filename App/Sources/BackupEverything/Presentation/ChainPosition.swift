import BackupCore
import Foundation

enum ChainPosition {
    static func label(index: Int, count: Int) -> String {
        "шаг \(index + 1) из \(count)"
    }

    static func label(of source: Source, chain: ChainState?) -> String? {
        let count = source.steps.count
        guard count > 1 else { return nil }
        return label(index: min(chain?.stepIndex ?? 0, count - 1), count: count)
    }

    static func note(_ note: String?, of source: Source, chain: ChainState?, status: SourceStatus) -> String? {
        guard let note else { return nil }
        guard chain != nil || status.concernsChainStart, let label = label(of: source, chain: chain) else { return note }
        return "\(label) · \(note)"
    }

    static func running(_ step: SourceStep, status: String?) -> String {
        if let status { return status }
        switch step.kind {
        case .folder: return "копирует файлы…"
        case .command: return "выполняет команду…"
        case .file: return "забирает файл…"
        case .device: return "ждёт устройство…"
        }
    }

    static func canRunNow(_ source: Source, chain: ChainState?) -> Bool {
        let steps = source.steps
        guard let chain else { return true }
        return chain.failure != nil || chain.stepIndex >= steps.count || !steps[chain.stepIndex].needsHuman
    }
}

private extension SourceStatus {
    var concernsChainStart: Bool {
        switch self {
        case .exportDue, .deviceDue, .filesFound, .waiting, .waitingForDevice: true
        default: false
        }
    }
}
