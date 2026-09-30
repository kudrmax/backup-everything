import BackupCore
import SwiftUI

struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @AppStorage("selectedSource") private var storedSelection = ""
    @State private var draft: SourceDraft?
    @State private var isNew = false

    var body: some View {
        EditorLayout(items: model.config.sources, selection: $selection) { source in
            HStack(spacing: 8) {
                SourceIcon(source)
                Text(source.name)
            }
            .foregroundStyle(source.enabled ? .primary : .secondary)
        } addMenu: {
            Section("Из шаблона") {
                ForEach(model.templates) { template in
                    Button(template.name) { start(model.newSource(from: template), as: nil) }
                }
            }
            Section("Пустой, выбрать тип") {
                ForEach(SourceKindChoice.allCases) { choice in
                    Button(choice.title) { start(model.newSource(from: nil), as: choice) }
                }
            }
        } detail: {
            if let draft {
                SourceEditor(
                    draft: Binding(get: { self.draft ?? draft }, set: { self.draft = $0 }),
                    isNew: isNew,
                    onSave: save,
                    onDelete: delete,
                    onCancel: cancel
                )
                .id(draft.id)
            } else {
                EmptyState(symbol: "tray.and.arrow.up", title: "Источников пока нет", message: "Добавьте первый кнопкой «Добавить» слева.")
            }
        }
        .navigationTitle("Источники")
        .onAppear {
            let stored = UUID(uuidString: storedSelection).flatMap { model.config.source($0) }
            selection = (stored ?? model.config.sources.first)?.id
        }
        .onChange(of: selection) { _, id in
            guard let id, let source = model.config.source(id) else { return }
            storedSelection = id.uuidString
            draft = SourceDraft(source)
            isNew = false
        }
    }

    private func start(_ source: Source, as choice: SourceKindChoice?) {
        var newDraft = SourceDraft(source)
        if let choice { newDraft.kindChoice = choice }
        selection = nil
        draft = newDraft
        isNew = true
    }

    private func save(_ source: Source) {
        Task {
            await model.save(source)
            isNew = false
            draft = SourceDraft(source)
            selection = source.id
        }
    }

    private func delete(_ source: Source) {
        Task {
            await model.delete(source)
            showFirst()
        }
    }

    private func cancel() {
        if !isNew, let id = draft?.id, let saved = model.config.source(id) {
            draft = SourceDraft(saved)
        } else {
            showFirst()
        }
    }

    private func showFirst() {
        isNew = false
        draft = model.config.sources.first.map(SourceDraft.init)
        selection = draft?.id
    }
}

struct SourceEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: SourceDraft
    let isNew: Bool
    let onSave: (Source) -> Void
    let onDelete: (Source) -> Void
    let onCancel: () -> Void

    @State private var previews: [RetentionPreview]?
    @State private var confirmsDeletion = false

    var body: some View {
        EditorPage {
            EditorHeader(name: $draft.name, prompt: "Название") {
                Button {
                    if let file = IconImporter.chooseFile(), let icon = model.importIcon(from: file) { draft.icon = icon }
                } label: {
                    SourceIcon(icon: draft.icon, symbol: symbol, size: 22)
                }
                .buttonStyle(.plain)
                .help("Выбрать значок")
            } accessory: {
                Toggle("Включён", isOn: $draft.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help(draft.enabled ? "Включён" : "Выключен")
                if !isNew || draft.icon != nil {
                    Menu {
                        if draft.icon != nil {
                            Button("Убрать значок") { draft.icon = nil }
                        }
                        if !isNew {
                            Button("Удалить источник…", role: .destructive) { confirmsDeletion = true }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            TextField("", text: $draft.description, prompt: Text("Описание: что здесь бэкапится"), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 40)
                .padding(.top, -8)
                .padding(.bottom, 4)
        } content: {
            SettingsSection(title: "Как часто и куда", isProminent: true) {
                SettingsRow(title: draft.kindChoice == .manualExport ? "Напоминать об экспорте" : "Как часто") {
                    Picker("", selection: $draft.schedule) {
                        ForEach(Schedule.allCases, id: \.self) { Text(Texts.schedule($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow(title: "Куда") {
                    if model.config.destinations.isEmpty {
                        Text("сначала добавьте назначение").foregroundStyle(.secondary)
                    } else {
                        TrailingFlow {
                            ForEach(model.config.destinations) { destination in
                                Chip(
                                    title: destination.name,
                                    symbol: StatusStyle.symbol(for: destination.kind),
                                    isOn: membership(of: destination.id)
                                )
                            }
                        }
                    }
                }
            }
            kindCard
            if draft.kindChoice == .manualExport {
                SettingsSection(title: "Инструкция: как выгружать файл") {
                    instructionsEditor.padding(10)
                }
            }
            SettingsSection(title: "Дополнительно") {
                DisclosureRow(title: "Хранить копии", summary: RetentionPlan.summary(draft.retention)) {
                    RetentionEditor(rules: $draft.retention, showCopies: isNew ? nil : {
                        let source = draft.build()
                        Task { previews = await model.retentionPreview(for: source) }
                    })
                }
                if draft.kindChoice != .manualExport {
                    DisclosureRow(title: "Инструкция", summary: instructionsSummary) {
                        instructionsEditor
                    }
                }
            }
        } saveBar: {
            if isNew || draft.hasChanges {
                SaveBar(isNew: isNew, problem: draft.problem, warning: conflictWarning, cancel: onCancel) {
                    onSave(draft.build())
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: isNew || draft.hasChanges)
        .sheet(isPresented: Binding(get: { previews != nil }, set: { if !$0 { previews = nil } })) {
            RetentionPreviewSheet(previews: previews ?? [])
        }
        .confirmationDialog("Удалить источник «\(draft.name)»?", isPresented: $confirmsDeletion) {
            Button("Удалить источник", role: .destructive) { onDelete(draft.build()) }
        } message: {
            Text("Уже сделанные копии в назначениях останутся на месте.")
        }
    }

    private var symbol: String {
        switch draft.kindChoice {
        case .folder: "folder"
        case .command: "terminal"
        case .manualExport: "square.and.arrow.down"
        }
    }

    private var instructionsEditor: some View {
        TextEditor(text: $draft.instructions)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: 120)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var kindCard: some View {
        switch draft.kindChoice {
        case .folder:
            SettingsSection(title: "Что бэкапить · тип «Папка»") {
                SettingsRow(title: "Папка или файл") {
                    PathField(path: $draft.folderPath, allowsFiles: true)
                }
                DisclosureRow(title: "Не копировать", summary: excludesSummary) {
                    CodeEditor(text: $draft.excludesText, minHeight: 60)
                    Text("По одной маске в строке, например *.tmp")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        case .command:
            SettingsSection(title: "Что бэкапить · тип «Команда»: результат команды") {
                CodeEditor(text: $draft.command, minHeight: 130)
                    .padding(10)
                SettingsRow(
                    title: "Останавливать через",
                    tip: "Команда должна сложить результат в папку $BACKUP_OUTPUT_DIR.\nДля временных файлов есть $BACKUP_SCRATCH_DIR."
                ) {
                    Stepper("\(draft.timeoutMinutes) мин", value: $draft.timeoutMinutes, in: 1...720)
                }
            }
        case .manualExport:
            SettingsSection(title: "Что бэкапить · тип «Ручной экспорт»: файл, который ты выгружаешь сам") {
                SettingsRow(title: "Куда попадает файл") {
                    PathField(path: $draft.watchPath)
                }
                SettingsRow(title: "Маска файла") {
                    TextField("", text: $draft.filePattern, prompt: Text("например, takeout-*.zip"))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced())
                }
                SettingsRow(title: "Файлов в одном экспорте") {
                    Picker("", selection: $draft.fileMode) {
                        Text("Один — забирать сразу").tag(FileMode.single)
                        Text("Несколько — ждать «Забрать»").tag(FileMode.multiple)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow(title: "После бэкапа убирать файл в Корзину") {
                    Toggle("", isOn: $draft.removeOriginal)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }
        }
    }

    private var excludesSummary: String {
        let masks = draft.excludesText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return masks.isEmpty ? "ничего" : masks.joined(separator: ", ")
    }

    private var instructionsSummary: String {
        let firstLine = draft.instructions.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? "нет" : firstLine
    }

    private var conflictWarning: String? {
        guard draft.kindChoice == .manualExport else { return nil }
        let conflicts = model.maskConflicts(for: draft.build())
        guard !conflicts.isEmpty else { return nil }
        return "Маска пересекается с источником «\(conflicts.map(\.name).joined(separator: "», «"))» в той же папке."
    }

    private func membership(of id: UUID) -> Binding<Bool> {
        Binding(
            get: { draft.destinationIds.contains(id) },
            set: { isMember in
                if isMember {
                    draft.destinationIds.insert(id)
                } else {
                    draft.destinationIds.remove(id)
                }
            }
        )
    }
}

struct RetentionPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let previews: [RetentionPreview]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Хранение копий").font(.title3.weight(.semibold))
            if previews.isEmpty {
                Text("У источника не выбраны назначения.").foregroundStyle(.secondary)
            }
            List {
                ForEach(previews) { preview in
                    Section(preview.destination.name) {
                        if preview.kept.isEmpty && preview.doomed.isEmpty {
                            Text("Копий пока нет или назначение недоступно.").foregroundStyle(.secondary)
                        }
                        ForEach(preview.kept, id: \.self) { snapshot in
                            Label(Texts.dateTime(snapshot.date), systemImage: "checkmark.circle").foregroundStyle(.primary)
                        }
                        ForEach(preview.doomed, id: \.self) { snapshot in
                            Label("\(Texts.dateTime(snapshot.date)) — будет удалена", systemImage: "trash").foregroundStyle(.red)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 460)
    }
}
