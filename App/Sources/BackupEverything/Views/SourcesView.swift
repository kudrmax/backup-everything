import BackupCore
import SwiftUI

struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @AppStorage("selectedSource") private var storedSelection = ""
    @State private var draft: SourceDraft?
    @State private var isNew = false

    var body: some View {
        EditorLayout(items: model.config.sources, selection: $selection, reorder: { ids in Task { await model.orderSources(ids) } }) { source in
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
            Section("Пустой — с чего начать") {
                ForEach(SourceStart.allCases) { choice in
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

    private func start(_ source: Source, as choice: SourceStart?) {
        var newDraft = SourceDraft(source)
        if let choice { newDraft.steps = choice.steps }
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
            EditorHeader(name: $draft.name, prompt: "Название", isNameEditable: isNew) {
                Button {
                    if let file = IconImporter.chooseFile(), let icon = model.importIcon(from: file) { draft.icon = icon }
                } label: {
                    SourceIcon(icon: draft.icon, symbol: symbol, size: 22)
                }
                .buttonStyle(.plainPointing)
                .hoverTip("Выбрать значок")
            } accessory: {
                Toggle("Включён", isOn: $draft.enabled)
                    .toggleStyle(.switch)
                    .pointing()
                    .controlSize(.small)
                    .labelsHidden()
                    .hoverTip(draft.enabled ? "Включён" : "Выключен")
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
                    .pointing()
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
                SettingsRow(title: "Как часто") {
                    Picker("", selection: $draft.schedule) {
                        ForEach(Schedule.allCases, id: \.self) { Text(Texts.schedule($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .pointing()
                }
                if !isNew, let saved = model.config.source(draft.id) {
                    SettingsRow(title: "Следующий бэкап") {
                        Text(NextBackup.detail(saved, nextDue: model.nextDue(of: saved), isWaiting: model.isWaitingForPerson(saved)))
                            .foregroundStyle(.secondary)
                    }
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
            StepsEditor(steps: $draft.steps, currentIndex: isNew ? nil : model.chain(of: draft.id)?.stepIndex)
            SettingsSection(title: "Дополнительно") {
                DisclosureRow(title: "Хранить копии", summary: RetentionPlan.summary(draft.retention)) {
                    RetentionEditor(rules: $draft.retention, showCopies: isNew ? nil : {
                        let source = draft.build()
                        Task { previews = await model.retentionPreview(for: source) }
                    })
                }
                DisclosureRow(title: "Инструкция: как настроить один раз", summary: instructionsSummary) {
                    instructionsEditor
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
        draft.symbol
    }

    private var instructionsEditor: some View {
        TextEditor(text: $draft.instructions)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: 120)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private var instructionsSummary: String {
        let firstLine = draft.instructions.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? "нет" : firstLine
    }

    private var conflictWarning: String? {
        guard draft.steps.contains(where: { $0.kindChoice == .file }) else { return nil }
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
