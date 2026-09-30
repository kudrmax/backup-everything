import BackupCore
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var onlyProblems = false

    var body: some View {
        Group {
            if runs.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath", title: "История пуста", message: "Здесь появятся все прогоны бэкапов.")
            } else {
                List(runs) { run in
                    RunRow(run: run)
                }
            }
        }
        .navigationTitle("История")
        .toolbar {
            Toggle("Только проблемы", isOn: $onlyProblems)
        }
    }

    private var runs: [RunRecord] {
        onlyProblems ? model.runs.filter { $0.firstFailure != nil } : model.runs
    }
}

struct RunRow: View {
    let run: RunRecord

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let snapshotName = run.snapshotName {
                    detail("Копия", "\(snapshotName), файлов: \(run.fileCount ?? 0), \(Texts.bytes(run.totalBytes ?? 0))")
                }
                ForEach(run.deliveries, id: \.destinationId) { delivery in
                    detail(delivery.destinationName, Texts.outcome(delivery.outcome))
                }
                if let failure = run.collectError ?? run.firstFailure {
                    HStack(alignment: .top) {
                        Text(failure)
                            .font(.callout.monospaced())
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        CopyButton(text: failure)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Скопировать ошибку")
                    }
                }
                if let details = run.details {
                    Text(details)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: StatusStyle.symbol(severity)).foregroundStyle(StatusStyle.color(severity))
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(run.sourceName).fontWeight(.medium)
                        Text(Texts.trigger(run.trigger)).foregroundStyle(.secondary)
                        Spacer()
                        Text(Texts.dateTime(run.startedAt)).foregroundStyle(.secondary)
                    }
                    Text(Texts.runSummary(run)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }

    private var severity: OverallStatus {
        if run.firstFailure != nil { return .error }
        return run.deliveries.allSatisfy(\.outcome.isDelivered) ? .ok : .attention
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
        .font(.callout)
    }
}
