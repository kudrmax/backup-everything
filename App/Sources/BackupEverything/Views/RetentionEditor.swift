import BackupCore
import SwiftUI

struct RetentionEditor: View {
    @Binding var rules: RetentionRules
    let showCopies: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                ForEach(RetentionPlan.stages(rules)) { stage in
                    GridRow {
                        Text(stage.lead)
                        Text("for the last")
                        Stepper(value: count(of: stage.unit), in: 0...range(of: stage.unit)) {
                            Text("\(stage.count)").monospacedDigit()
                        }
                        .gridColumnAlignment(.trailing)
                        .pointing()
                        Text(stage.isKept ? stage.tail : "\(stage.tail) — not used")
                            .fixedSize()
                    }
                    .opacity(stage.isKept ? 1 : 0.45)
                }
            }
            Text(keepsHistory ? RetentionPlan.footnote : RetentionPlan.newestOnly)
                .foregroundStyle(.secondary)
            if let showCopies {
                Button("Show copies by date…", action: showCopies)
                    .controlSize(.small)
            }
        }
    }

    private var keepsHistory: Bool {
        RetentionPlan.stages(rules).contains(where: \.isKept)
    }

    private func count(of unit: RetentionStage.Unit) -> Binding<Int> {
        switch unit {
        case .day: $rules.daily
        case .week: $rules.weekly
        case .month: $rules.monthly
        case .year: $rules.yearly
        }
    }

    private func range(of unit: RetentionStage.Unit) -> Int {
        switch unit {
        case .day: 365
        case .week: 104
        case .month: 120
        case .year: 50
        }
    }
}
