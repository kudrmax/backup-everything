import BackupCore
import SwiftUI

struct RetentionEditor: View {
    @Binding var rules: RetentionRules
    let schedule: Schedule
    let showCopies: (() -> Void)?

    @State private var isCustom: Bool

    init(rules: Binding<RetentionRules>, schedule: Schedule, showCopies: (() -> Void)?) {
        _rules = rules
        self.schedule = schedule
        self.showCopies = showCopies
        let preset = RetentionPreset.matching(rules.wrappedValue)
        _isCustom = State(initialValue: preset.map { !RetentionPreset.offered(for: schedule).contains($0) } ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("За какой срок")
                Spacer()
                Picker("", selection: selection) {
                    ForEach(RetentionPreset.offered(for: schedule)) { Text($0.title).tag(Optional($0)) }
                    Text("своё").tag(RetentionPreset?.none)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            RetentionTimeline(steps: RetentionPlan.steps(rules))
            Text(RetentionPlan.explanation(rules, schedule: schedule))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isCustom {
                VStack(spacing: 6) {
                    stepRow("По копии на каждый день", unit: .day, value: $rules.daily, range: 0...365)
                    stepRow("По копии на каждую неделю", unit: .week, value: $rules.weekly, range: 0...104)
                    stepRow("По копии на каждый месяц", unit: .month, value: $rules.monthly, range: 0...120)
                    stepRow("По копии на каждый год", unit: .year, value: $rules.yearly, range: 0...50)
                }
            }
            if let showCopies {
                Button("Показать копии по датам…", action: showCopies)
                    .controlSize(.small)
            }
        }
    }

    private var selection: Binding<RetentionPreset?> {
        Binding(
            get: { isCustom ? nil : RetentionPreset.matching(rules) },
            set: { preset in
                isCustom = preset == nil
                if let preset { rules = preset.rules }
            }
        )
    }

    private func stepRow(_ title: String, unit: RetentionStep.Unit, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Stepper(value: value, in: range) {
                Text(value.wrappedValue == 0 ? "не хранить" : "за \(RetentionStep(unit: unit, count: value.wrappedValue).span)")
                    .monospacedDigit()
                    .foregroundStyle(value.wrappedValue == 0 ? .secondary : .primary)
            }
        }
    }
}

struct RetentionTimeline: View {
    private static let dotLimit = 12

    let steps: [RetentionStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("сегодня")
                Rectangle().fill(.separator).frame(height: 1)
                Text("раньше")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            HStack(alignment: .top, spacing: 20) {
                if steps.isEmpty {
                    segment(dots: 1, gap: 0, title: "последняя копия", subtitle: "")
                }
                ForEach(steps) { step in
                    segment(dots: min(step.count, Self.dotLimit), gap: gap(of: step.unit), title: step.rhythm, subtitle: step.length)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func segment(dots: Int, gap: CGFloat, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: gap) {
                ForEach(0..<dots, id: \.self) { _ in
                    Circle().fill(.tint).frame(width: 7, height: 7)
                }
            }
            .frame(height: 10)
            Text(title).font(.caption)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private func gap(of unit: RetentionStep.Unit) -> CGFloat {
        switch unit {
        case .day: 3
        case .week: 8
        case .month: 11
        case .year: 16
        }
    }
}
