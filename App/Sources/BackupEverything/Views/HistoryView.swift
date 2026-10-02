import BackupCore
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var onlyProblems = false

    var body: some View {
        Group {
            if runs.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath", title: "No history yet", message: "Every backup run will show up here.")
            } else {
                List(runs) { run in
                    RunRow(run: run)
                }
            }
        }
        .navigationTitle("History")
        .toolbar {
            Toggle("Problems only", isOn: $onlyProblems)
        }
    }

    private var runs: [RunRecord] {
        RunHistory.runs(model.runs, onlyProblems: onlyProblems)
    }
}

struct RunRow: View {
    let run: RunRecord

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let copy = RunHistory.copyLine(run) {
                    detail("Copy", copy)
                }
                ForEach(run.deliveries, id: \.destinationId) { delivery in
                    detail(delivery.destinationName, Texts.outcome(delivery.outcome))
                }
                if let failure = RunHistory.failure(run) {
                    HStack(alignment: .top) {
                        Text(failure)
                            .font(.callout.monospaced())
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        CopyButton(text: failure)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderlessPointing)
                            .hoverTip("Copy error")
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
        RunHistory.severity(run)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
        .font(.callout)
    }
}
