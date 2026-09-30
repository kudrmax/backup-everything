import BackupCore
import SwiftUI

struct StepsEditor: View {
    @Binding var steps: [StepDraft]
    let currentIndex: Int?

    var body: some View {
        SettingsSection(title: steps.count > 1 ? "Что делать · шаги выполняются по очереди" : "Что делать") {
            ForEach($steps) { $step in
                let index = steps.firstIndex { $0.id == step.id } ?? 0
                StepCard(
                    step: $step,
                    number: steps.count > 1 ? index + 1 : nil,
                    isCurrent: index == currentIndex,
                    followedByFolder: steps[(index + 1)...].contains { $0.kindChoice == .folder },
                    canMoveUp: index > 0,
                    canMoveDown: index < steps.count - 1,
                    move: { steps.swapAt(index, index + $0) },
                    remove: steps.count > 1 ? { steps.remove(at: index) } : nil
                )
            }
            HStack {
                Menu("Добавить шаг") {
                    ForEach(StepKindChoice.allCases) { choice in
                        Button(choice.title, systemImage: choice.symbol) { steps.append(StepDraft(new: choice)) }
                    }
                }
                .fixedSize()
                .pointing()
                Spacer()
            }
            .padding(10)
        }
    }
}

private struct StepCard: View {
    @Binding var step: StepDraft
    let number: Int?
    let isCurrent: Bool
    let followedByFolder: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let remove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            switch step.kindChoice {
            case .folder: folderFields
            case .command: commandFields
            case .file: fileFields
            case .device: deviceFields
            }
        }
        .background(isCurrent ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.clear))
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let number {
                Text("\(number)")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 18)
            }
            Image(systemName: step.kindChoice.symbol)
                .foregroundStyle(.secondary)
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
            .pointing()
            if number != nil {
                Button { move(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(!canMoveUp)
                    .hoverTip("Выше")
                Button { move(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(!canMoveDown)
                    .hoverTip("Ниже")
            }
            if let remove {
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .hoverTip("Удалить шаг")
            }
        }
        .buttonStyle(.borderlessPointing)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var instructionsEditor: some View {
        TextEditor(text: $step.instructions)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: 80)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .hoverTip("Инструкция: что нужно сделать руками")
    }

    @ViewBuilder
    private var folderFields: some View {
        SettingsRow(title: "Папка или файл") {
            PathField(path: $step.folderPath, allowsFiles: true)
        }
        DisclosureRow(title: "Не копировать", summary: step.excludes.isEmpty ? "ничего" : step.excludes.joined(separator: ", ")) {
            CodeEditor(text: $step.excludesText, minHeight: 60)
            Text("По одной маске в строке, например *.tmp")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var commandFields: some View {
        CodeEditor(text: $step.command, minHeight: 130)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        SettingsRow(
            title: "Останавливать через",
            tip: "Результат — в $BACKUP_OUTPUT_DIR.\nФайлы от тебя, не входящие в копию, — в $BACKUP_INPUT_DIR.\nДля временных файлов есть $BACKUP_SCRATCH_DIR."
        ) {
            Stepper("\(step.timeoutMinutes) мин", value: $step.timeoutMinutes, in: 1...720)
                .pointing()
        }
    }

    @ViewBuilder
    private var fileFields: some View {
        instructionsEditor
        SettingsRow(title: "Куда попадает файл") {
            PathField(path: $step.watchPath)
        }
        SettingsRow(title: "Маска файла") {
            TextField("", text: $step.filePattern, prompt: Text("например, manifest-*.json"))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.body.monospaced())
        }
        SettingsRow(title: "Файлов в одном экспорте") {
            Picker("", selection: $step.fileMode) {
                Text("Один — забирать сразу").tag(FileMode.single)
                Text("Несколько — ждать «Забрать»").tag(FileMode.multiple)
            }
            .labelsHidden()
            .fixedSize()
            .pointing()
        }
        SettingsRow(title: "Сохранять этот файл в бэкапе", tip: "Выключите, если файл нужен только следующим шагам.") {
            Toggle("", isOn: $step.includeInCopy)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .pointing()
        }
        SettingsRow(title: "Убирать оригинал в Корзину", tip: "Выключите, чтобы файл остался в папке, а в бэкап ушла копия.") {
            Toggle("", isOn: $step.removeOriginal)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .pointing()
        }
    }

    @ViewBuilder
    private var deviceFields: some View {
        instructionsEditor
        SettingsRow(
            title: "Путь на устройстве",
            tip: "Шаг ждёт, пока этот путь появится — то есть пока устройство подключено.\nЕсли оставить пустым, берётся папка следующего шага."
        ) {
            TextField("", text: $step.devicePath, prompt: Text(followedByFolder ? "папка следующего шага" : "/Volumes/…"))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
        }
    }
}
