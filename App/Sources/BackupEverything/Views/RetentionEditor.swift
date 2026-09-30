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
                        Text(stage.prefix)
                            .gridColumnAlignment(.trailing)
                        Stepper(value: count(of: stage.unit), in: 0...range(of: stage.unit)) {
                            Text("\(stage.count)").monospacedDigit()
                        }
                        .gridColumnAlignment(.trailing)
                        .pointing()
                        Text(stage.unitName)
                        Text(stage.effect)
                            .fixedSize()
                            .foregroundStyle(.secondary)
                            .padding(.leading, 8)
                    }
                    .opacity(stage.isKept ? 1 : 0.45)
                }
                if keepsHistory {
                    GridRow {
                        Text("Потом")
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Text("удаляются")
                            .foregroundStyle(.secondary)
                            .padding(.leading, 8)
                    }
                }
            }
            if !keepsHistory {
                Text("Хранится только самая свежая копия.")
                    .foregroundStyle(.secondary)
            }
            if let showCopies {
                Button("Показать копии по датам…", action: showCopies)
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
