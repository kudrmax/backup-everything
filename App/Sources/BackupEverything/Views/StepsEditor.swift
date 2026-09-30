import BackupCore
import SwiftUI

struct StepsEditor: View {
    @Binding var steps: [StepDraft]
    let currentIndex: Int?

    var body: some View {
        SettingsSection(title: "Что бэкапить · тип «По шагам»: шаги выполняются по очереди") {
            ForEach($steps) { $step in
                let index = steps.firstIndex { $0.id == step.id } ?? 0
                StepCard(
                    step: $step,
                    number: index + 1,
                    isCurrent: index == currentIndex,
                    canMoveUp: index > 0,
                    canMoveDown: index < steps.count - 1,
                    move: { steps.swapAt(index, index + $0) },
                    remove: { steps.remove(at: index) }
                )
            }
            HStack {
                Menu("Добавить шаг") {
                    ForEach(StepKindChoice.allCases) { choice in
                        Button(choice.title) { steps.append(StepDraft(new: choice)) }
                    }
                }
                .fixedSize()
                Spacer()
            }
            .padding(10)
        }
    }
}

private struct StepCard: View {
    @Binding var step: StepDraft
    let number: Int
    let isCurrent: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            switch step.kindChoice {
            case .manual: manualFields
            case .command: commandFields
            }
        }
        .background(isCurrent ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.clear))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            TextField("", text: $step.name, prompt: Text("Название шага"))
                .textFieldStyle(.plain)
                .font(.body.weight(.medium))
            if isCurrent {
                Text("сейчас здесь").font(.caption).foregroundStyle(.tint)
            }
            Picker("", selection: $step.kindChoice) {
                ForEach(StepKindChoice.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Button { move(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(!canMoveUp)
                .help("Выше")
            Button { move(1) } label: { Image(systemName: "chevron.down") }
                .disabled(!canMoveDown)
                .help("Ниже")
            Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                .help("Удалить шаг")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var manualFields: some View {
        TextEditor(text: $step.instructions)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: 80)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .help("Инструкция: что нужно сделать руками")
        SettingsRow(title: "Куда попадает файл") {
            PathField(path: $step.watchPath)
        }
        SettingsRow(title: "Маска файла") {
            TextField("", text: $step.filePattern, prompt: Text("например, manifest-*.json"))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.body.monospaced())
        }
        SettingsRow(
            title: "Сохранять этот файл в бэкапе",
            tip: "Выключите, если файл нужен только следующим шагам."
        ) {
            Toggle("", isOn: $step.includeInCopy)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private var commandFields: some View {
        CodeEditor(text: $step.command, minHeight: 130)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        SettingsRow(
            title: "Останавливать через",
            tip: "Результат — в $BACKUP_OUTPUT_DIR.\nФайлы ручных шагов, не входящие в копию, — в $BACKUP_INPUT_DIR.\nДля временных файлов есть $BACKUP_SCRATCH_DIR."
        ) {
            Stepper("\(step.timeoutMinutes) мин", value: $step.timeoutMinutes, in: 1...720)
        }
    }
}
