import AppKit
import BackupCore
import SwiftUI

struct DestinationsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @AppStorage("selectedDestination") private var storedSelection = ""
    @State private var draft: DestinationDraft?
    @State private var isNew = false

    var body: some View {
        HStack(spacing: 0) {
            List(model.config.destinations, selection: $selection) { destination in
                Label(destination.name, systemImage: StatusStyle.symbol(for: destination.kind)).tag(destination.id)
            }
            .frame(width: 230)
            Divider()
            if let draft {
                DestinationEditor(
                    draft: Binding(get: { self.draft ?? draft }, set: { self.draft = $0 }),
                    isNew: isNew,
                    onSave: save,
                    onDelete: delete,
                    onCancel: cancel
                )
                .id(draft.id)
            } else {
                EmptyState(symbol: "externaldrive", title: "Назначения", message: "Выберите назначение слева или добавьте новое кнопкой «+».")
            }
        }
        .navigationTitle("Назначения")
        .toolbar {
            Menu("Добавить", systemImage: "plus") {
                Button("Папка или внешний диск") { start(.localFolder(path: "")) }
                Button("Облако (rclone)") { start(.rclone(remote: "", path: "backups")) }
            }
        }
        .onAppear {
            if let id = UUID(uuidString: storedSelection), model.config.destination(id) != nil { selection = id }
        }
        .onChange(of: selection) { _, id in
            storedSelection = id?.uuidString ?? ""
            guard let id, let destination = model.config.destination(id) else { return }
            draft = DestinationDraft(destination)
            isNew = false
        }
    }

    private func start(_ kind: DestinationKind) {
        selection = nil
        draft = DestinationDraft(Destination(name: "", kind: kind))
        isNew = true
    }

    private func save(_ destination: Destination) {
        Task {
            await model.save(destination)
            isNew = false
            selection = destination.id
        }
    }

    private func delete(_ destination: Destination) {
        Task {
            await model.delete(destination)
            cancel()
        }
    }

    private func cancel() {
        draft = nil
        selection = nil
        isNew = false
    }
}

struct DestinationEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: DestinationDraft
    let isNew: Bool
    let onSave: (Destination) -> Void
    let onDelete: (Destination) -> Void
    let onCancel: () -> Void

    @State private var remotes: [String] = []
    @State private var confirmsDeletion = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Основное") {
                    TextField("Название", text: $draft.name, prompt: Text("например, Внешний HDD"))
                    Picker("Тип", selection: $draft.typeChoice) {
                        ForEach(DestinationTypeChoice.allCases) { Text($0.title).tag($0) }
                    }
                }
                switch draft.typeChoice {
                case .local: localSection
                case .rclone: rcloneSection
                }
                Section("Как часто должно быть доступно") {
                    Picker("Режим", selection: $draft.isPeriodic) {
                        Text("Всегда на связи").tag(false)
                        Text("Подключаю время от времени").tag(true)
                    }
                    if draft.isPeriodic {
                        Stepper("Напоминать подключить, если не было дней: \(draft.days)", value: $draft.days, in: 1...365)
                        Text("Пока срок не вышел, приложение молчит. При подключении диск получит свежую копию каждого источника.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if !isNew, let saved = model.config.destination(draft.id) {
                    DestinationInfo(destination: saved)
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .task(id: draft.typeChoice) {
            if draft.typeChoice == .rclone { remotes = await model.rcloneRemotes() }
        }
        .confirmationDialog("Удалить назначение «\(draft.name)»?", isPresented: $confirmsDeletion) {
            Button("Удалить назначение", role: .destructive) { onDelete(draft.build()) }
        } message: {
            Text("Копии, которые уже лежат в этом назначении, останутся на месте. Источники перестанут туда бэкапиться.")
        }
    }

    private var localSection: some View {
        Section("Папка") {
            HStack {
                TextField("Путь", text: $draft.path)
                Button("Выбрать…") {
                    if let path = FolderPicker.choose() { draft.path = path }
                }
            }
            Text("Для внешнего диска выберите папку на нём. Приложение не создаёт эту папку само: если диск не подключён, бэкап просто ждёт.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var rcloneSection: some View {
        Section("Облако") {
            if !model.isRcloneInstalled {
                Text("Не найден rclone. Установите его в терминале командой `brew install rclone` и откройте этот экран заново.")
                    .foregroundStyle(.orange)
            } else if remotes.isEmpty {
                Text("В rclone пока нет подключённых облаков. Выполните в терминале `rclone config`, выберите «n» (new remote), дайте имя, выберите сервис и пройдите вход в браузере. Затем нажмите «Обновить».")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Подключённое облако", selection: $draft.remote) {
                    Text("Не выбрано").tag("")
                    ForEach(remotes, id: \.self) { Text($0).tag($0) }
                }
            }
            TextField("Папка в облаке", text: $draft.remotePath)
            Button("Обновить список облаков") {
                Task { remotes = await model.rcloneRemotes() }
            }
        }
    }

    private var footer: some View {
        HStack {
            if !isNew {
                Button("Удалить", role: .destructive) { confirmsDeletion = true }
            }
            if let problem = draft.problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
            Spacer()
            Button("Отменить", action: onCancel)
            Button(isNew ? "Добавить" : "Сохранить") { onSave(draft.build()) }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.problem != nil)
        }
        .padding(12)
    }
}

struct DestinationInfo: View {
    @Environment(AppModel.self) private var model
    let destination: Destination

    @State private var isAvailable: Bool?
    @State private var usedBytes: Int64?
    @State private var snapshots: [UUID: [Snapshot]] = [:]

    var body: some View {
        Section("Состояние") {
            LabeledContent("Доступность") {
                switch isAvailable {
                case .none: ProgressView().controlSize(.small)
                case .some(true): Label("Доступно", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .some(false): Label("Недоступно", systemImage: "xmark.circle").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Занято", value: usedBytes.map(Texts.bytes) ?? "—")
            LabeledContent("Последний полный догон", value: model.lastCaughtUp(destination).map { Texts.relative($0) } ?? "—")
            let waiting = model.waitingSources(for: destination)
            if !waiting.isEmpty {
                LabeledContent("Ждут доставки", value: waiting.map(\.name).joined(separator: ", "))
            }
        }
        .task(id: destination) { await load() }
        ForEach(sources) { source in
            Section("Копии: \(source.name)") {
                let items = snapshots[source.id] ?? []
                if items.isEmpty {
                    Text("Копий пока нет.").foregroundStyle(.secondary)
                }
                ForEach(items, id: \.self) { snapshot in
                    HStack {
                        Text(Texts.dateTime(snapshot.date))
                        Spacer()
                        if let url = model.localURL(of: snapshot, source: source, in: destination) {
                            Button("Показать в Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        } else {
                            Text(snapshot.name).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private var sources: [Source] {
        model.config.sources.filter { $0.destinationIds.contains(destination.id) }
    }

    private func load() async {
        isAvailable = nil
        usedBytes = nil
        let available = await model.isAvailable(destination)
        isAvailable = available
        guard available else { return }
        for source in sources {
            snapshots[source.id] = await model.snapshots(of: source, in: destination)
        }
        usedBytes = await model.usedBytes(destination)
    }
}
