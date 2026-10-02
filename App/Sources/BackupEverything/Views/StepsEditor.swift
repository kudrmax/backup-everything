import BackupCore
import SwiftUI

struct StepsEditor: View {
    @Binding var steps: [StepDraft]
    let currentIndex: Int?

    var body: some View {
        SettingsSection(title: StepList.title(count: steps.count)) {
            ForEach($steps) { $step in
                let index = steps.firstIndex { $0.id == step.id } ?? 0
                StepCard(
                    step: $step,
                    number: StepList.number(of: index, count: steps.count),
                    isCurrent: index == currentIndex,
                    followedByFolder: StepList.isFollowedByFolder(steps, at: index),
                    canMoveUp: index > 0,
                    canMoveDown: index < steps.count - 1,
                    move: { steps.swapAt(index, index + $0) },
                    remove: steps.count > 1 ? { steps.remove(at: index) } : nil
                )
            }
            HStack {
                Menu("Add step") {
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
            TextField("", text: $step.name, prompt: Text("Step name"))
                .textFieldStyle(.plain)
                .font(.body.weight(.medium))
            if isCurrent {
                Text("now here").font(.caption).foregroundStyle(.tint)
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
                    .hoverTip("Move up")
                Button { move(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(!canMoveDown)
                    .hoverTip("Move down")
            }
            if let remove {
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .hoverTip("Delete step")
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
            .hoverTip("Instructions: what to do by hand")
    }

    @ViewBuilder
    private var folderFields: some View {
        SettingsRow(title: "Folder or file") {
            PathField(path: $step.folderPath, allowsFiles: true)
        }
        DisclosureRow(title: "Don’t copy", summary: step.excludesSummary) {
            CodeEditor(text: $step.excludesText, minHeight: 60)
            Text("One mask per line, e.g. *.tmp")
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
            title: "Stop after",
            tip: "Output goes to $BACKUP_OUTPUT_DIR.\nFiles from you that aren’t part of the copy are in $BACKUP_INPUT_DIR.\nUse $BACKUP_SCRATCH_DIR for temporary files."
        ) {
            Stepper("\(step.timeoutMinutes) min", value: $step.timeoutMinutes, in: 1...720)
                .pointing()
        }
    }

    @ViewBuilder
    private var fileFields: some View {
        instructionsEditor
        SettingsRow(title: "Where the file lands") {
            PathField(path: $step.watchPath)
        }
        SettingsRow(title: "File mask") {
            TextField("", text: $step.filePattern, prompt: Text("e.g. manifest-*.json"))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.body.monospaced())
        }
        SettingsRow(title: "Files per export") {
            Picker("", selection: $step.fileMode) {
                Text("One — pick up right away").tag(FileMode.single)
                Text("Several — wait for “Pick up”").tag(FileMode.multiple)
            }
            .labelsHidden()
            .fixedSize()
            .pointing()
        }
        SettingsRow(title: "Keep this file in the backup", tip: "Turn off if only the next steps need the file.") {
            Toggle("", isOn: $step.includeInCopy)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .pointing()
        }
        SettingsRow(title: "Move the original to the Trash", tip: "Turn off to leave the file in the folder and back up a copy.") {
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
            title: "Path on the device",
            tip: "The step waits until this path appears, i.e. until the device is connected.\nIf left empty, the next step’s folder is used."
        ) {
            TextField("", text: $step.devicePath, prompt: Text(followedByFolder ? "next step’s folder" : "/Volumes/…"))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
        }
    }
}
