import BackupCore
import SwiftUI

struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @AppStorage("selectedSource") private var storedSelection = ""
    @State private var draft: SourceDraft?
    @State private var isNew = false

    var body: some View {
        HStack(spacing: 0) {
            List(model.config.sources, selection: $selection) { source in
                Label(source.name, systemImage: StatusStyle.symbol(for: source.kind))
                    .foregroundStyle(source.enabled ? .primary : .secondary)
                    .tag(source.id)
            }
            .frame(width: 230)
            Divider()
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
                EmptyState(symbol: "tray.and.arrow.up", title: "Источники", message: "Выберите источник слева или добавьте новый кнопкой «+».")
            }
        }
        .navigationTitle("Источники")
        .toolbar {
            Menu("Добавить", systemImage: "plus") {
                Button("Пустой источник") { start(model.newSource(from: nil)) }
                Divider()
                ForEach(model.templates) { template in
                    Button(template.name) { start(model.newSource(from: template)) }
                }
            }
        }
        .onAppear {
            if let id = UUID(uuidString: storedSelection), model.config.source(id) != nil { selection = id }
        }
        .onChange(of: selection) { _, id in
            storedSelection = id?.uuidString ?? ""
            guard let id, let source = model.config.source(id) else { return }
            draft = SourceDraft(source)
            isNew = false
        }
    }

    private func start(_ source: Source) {
        selection = nil
        draft = SourceDraft(source)
        isNew = true
    }

    private func save(_ source: Source) {
        Task {
            await model.save(source)
            isNew = false
            selection = source.id
        }
    }

    private func delete(_ source: Source) {
        Task {
            await model.delete(source)
            cancel()
        }
    }

    private func cancel() {
        draft = nil
        selection = nil
        isNew = false
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
        VStack(spacing: 0) {
            Form {
                Section("Основное") {
                    TextField("Название", text: $draft.name)
                    Toggle("Включён", isOn: $draft.enabled)
                    Picker("Тип", selection: $draft.kindChoice) {
                        ForEach(SourceKindChoice.allCases) { Text($0.title).tag($0) }
                    }
                }
                kindSection
                Section("Расписание") {
                    Picker(draft.kindChoice == .manualExport ? "Напоминать об экспорте" : "Запускать", selection: $draft.schedule) {
                        ForEach(Schedule.allCases, id: \.self) { Text(Texts.schedule($0)).tag($0) }
                    }
                }
                Section("Куда бэкапить") {
                    if model.config.destinations.isEmpty {
                        Text("Сначала добавьте назначение в разделе «Назначения».").foregroundStyle(.secondary)
                    }
                    ForEach(model.config.destinations) { destination in
                        Toggle(isOn: membership(of: destination.id)) {
                            Label(destination.name, systemImage: StatusStyle.symbol(for: destination.kind))
                        }
                    }
                }
                Section("Сколько хранить") {
                    Stepper("По одной копии за последние дни: \(draft.retention.daily)", value: $draft.retention.daily, in: 0...365)
                    Stepper("По одной в неделю, недель: \(draft.retention.weekly)", value: $draft.retention.weekly, in: 0...104)
                    Stepper("По одной в месяц, месяцев: \(draft.retention.monthly)", value: $draft.retention.monthly, in: 0...120)
                    Stepper("По одной в год, лет: \(draft.retention.yearly)", value: $draft.retention.yearly, in: 0...50)
                    Text("Самая свежая копия хранится всегда.").font(.callout).foregroundStyle(.secondary)
                    if !isNew {
                        Button("Показать, что останется и что удалится") {
                            let source = draft.build()
                            Task { previews = await model.retentionPreview(for: source) }
                        }
                    }
                }
                Section("Инструкция") {
                    TextEditor(text: $draft.instructions)
                        .font(.body)
                        .frame(minHeight: 110)
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .sheet(isPresented: Binding(get: { previews != nil }, set: { if !$0 { previews = nil } })) {
            RetentionPreviewSheet(previews: previews ?? [])
        }
        .confirmationDialog("Удалить источник «\(draft.name)»?", isPresented: $confirmsDeletion) {
            Button("Удалить источник", role: .destructive) { onDelete(draft.build()) }
        } message: {
            Text("Уже сделанные копии в назначениях останутся на месте.")
        }
    }

    @ViewBuilder
    private var kindSection: some View {
        switch draft.kindChoice {
        case .folder:
            Section("Папка или файл") {
                HStack {
                    TextField("Путь", text: $draft.folderPath)
                    Button("Выбрать…") {
                        if let path = FolderPicker.choose(allowsFiles: true) { draft.folderPath = path }
                    }
                }
                VStack(alignment: .leading) {
                    Text("Не копировать (по одной маске в строке)")
                    TextEditor(text: $draft.excludesText)
                        .font(.body.monospaced())
                        .frame(minHeight: 50)
                }
            }
        case .command:
            Section("Команда") {
                TextEditor(text: $draft.command)
                    .font(.body.monospaced())
                    .frame(minHeight: 120)
                Stepper("Останавливать через, минут: \(draft.timeoutMinutes)", value: $draft.timeoutMinutes, in: 1...720)
                Text("Команда должна сложить результат в папку $BACKUP_OUTPUT_DIR. Для временных файлов есть $BACKUP_SCRATCH_DIR.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .manualExport:
            Section("Ручной экспорт") {
                HStack {
                    TextField("Куда попадает файл", text: $draft.watchPath)
                    Button("Выбрать…") {
                        if let path = FolderPicker.choose() { draft.watchPath = path }
                    }
                }
                TextField("Маска файла", text: $draft.filePattern, prompt: Text("например, takeout-*.zip"))
                Picker("Файлов в одном экспорте", selection: $draft.fileMode) {
                    Text("Один — забирать сразу").tag(FileMode.single)
                    Text("Несколько — ждать «Готово, забрать»").tag(FileMode.multiple)
                }
                Toggle("Убирать файл из папки в Корзину после бэкапа", isOn: $draft.removeOriginal)
            }
        }
    }

    private var footer: some View {
        HStack {
            if !isNew {
                Button("Удалить", role: .destructive) { confirmsDeletion = true }
            }
            VStack(alignment: .leading, spacing: 2) {
                if let problem = draft.problem {
                    Text(problem).foregroundStyle(.red)
                }
                if !conflicts.isEmpty {
                    Text("Маска пересекается с источником «\(conflicts.map(\.name).joined(separator: "», «"))» в той же папке.")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            Spacer()
            Button("Отменить", action: onCancel)
            Button(isNew ? "Добавить" : "Сохранить") { onSave(draft.build()) }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.problem != nil)
        }
        .padding(12)
    }

    private var conflicts: [Source] {
        draft.kindChoice == .manualExport ? model.maskConflicts(for: draft.build()) : []
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
