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
        EditorLayout(items: model.config.destinations, selection: $selection) { destination in
            HStack(spacing: 11) {
                DestinationIcon(destination: destination).frame(width: 18)
                Text(destination.name)
            }
        } addMenu: {
            Button("Папка или внешний диск") { start(.localFolder(path: "")) }
            Button("Облако (rclone)") { start(.rclone(remote: "", path: "backups")) }
        } detail: {
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
                EmptyState(symbol: "externaldrive", title: "Назначений пока нет", message: "Добавьте папку, диск или облако кнопкой «Добавить» слева.")
            }
        }
        .navigationTitle("Назначения")
        .onAppear {
            let stored = UUID(uuidString: storedSelection).flatMap { model.config.destination($0) }
            selection = (stored ?? model.config.destinations.first)?.id
        }
        .onChange(of: selection) { _, id in
            guard let id, let destination = model.config.destination(id) else { return }
            storedSelection = id.uuidString
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
            draft = DestinationDraft(destination)
            selection = destination.id
        }
    }

    private func delete(_ destination: Destination) {
        Task {
            await model.delete(destination)
            showFirst()
        }
    }

    private func cancel() {
        if !isNew, let id = draft?.id, let saved = model.config.destination(id) {
            draft = DestinationDraft(saved)
        } else {
            showFirst()
        }
    }

    private func showFirst() {
        isNew = false
        draft = model.config.destinations.first.map(DestinationDraft.init)
        selection = draft?.id
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

    private var saved: Destination? {
        isNew ? nil : model.config.destination(draft.id)
    }

    var body: some View {
        EditorPage {
            EditorHeader(name: $draft.name, prompt: draft.typeChoice == .local ? "Название, например Внешний HDD" : "Название, например Облако") {
                if let saved {
                    DestinationIcon(destination: saved)
                        .hoverTip(DestinationDetails.text(of: saved, model: model))
                } else {
                    Image(systemName: draft.typeChoice == .local ? "externaldrive" : "cloud").foregroundStyle(.secondary)
                }
            } accessory: {
                if let saved {
                    Menu {
                        Button("Удалить…", role: .destructive) { confirmsDeletion = true }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .pointing()
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .id(saved.id)
                }
            }
            if let saved, let attention = attention(for: saved) {
                Text(attention)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.leading, 40)
                    .padding(.top, -8)
            }
        } content: {
            SettingsCard {
                switch draft.typeChoice {
                case .local: localRows
                case .rclone: rcloneRows
                }
                SettingsRow(title: "Подключение") {
                    Picker("", selection: $draft.isPeriodic) {
                        Text("Всегда на связи").tag(false)
                        Text("Время от времени").tag(true)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .pointing()
                }
                if draft.isPeriodic {
                    SettingsRow(
                        title: "Напоминать, если не подключал",
                        tip: "Пока срок не вышел, приложение молчит.\nПри подключении диск получит свежую копию каждого источника."
                    ) {
                        Stepper("\(draft.days) дн", value: $draft.days, in: 1...365)
                        .pointing()
                    }
                }
            }
            if let saved {
                DestinationCopies(destination: saved)
            }
        } saveBar: {
            if isNew || draft.hasChanges {
                SaveBar(isNew: isNew, problem: draft.problem, cancel: onCancel) {
                    onSave(draft.build())
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: isNew || draft.hasChanges)
        .task(id: draft.typeChoice) {
            if draft.typeChoice == .rclone { remotes = await model.rcloneRemotes() }
        }
        .confirmationDialog("Удалить назначение «\(draft.name)»?", isPresented: $confirmsDeletion) {
            Button("Удалить назначение", role: .destructive) { onDelete(draft.build()) }
        } message: {
            Text("Копии, которые уже лежат в этом назначении, останутся на месте. Источники перестанут туда бэкапиться.")
        }
    }

    private func attention(for destination: Destination) -> String? {
        let waiting = model.waitingSources(for: destination).map(\.name)
        let parts = [
            model.condition(of: destination).problem,
            waiting.isEmpty ? nil : "ждут: \(waiting.joined(separator: ", "))",
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var localRows: some View {
        SettingsRow(
            title: "Папка",
            tip: "Для внешнего диска выберите папку на нём.\nПриложение не создаёт эту папку само:\nесли диск не подключён, бэкап просто ждёт."
        ) {
            PathField(path: $draft.path)
        }
    }

    @ViewBuilder
    private var rcloneRows: some View {
        if !model.isRcloneInstalled {
            Text("Не найден rclone. Установите его в терминале командой `brew install rclone` и откройте этот экран заново.")
                .foregroundStyle(.orange)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if remotes.isEmpty {
            HStack(alignment: .top) {
                Text("В rclone пока нет подключённых облаков. Выполните в терминале `rclone config`, выберите «n» (new remote), дайте имя, выберите сервис и пройдите вход в браузере.")
                    .foregroundStyle(.secondary)
                Spacer()
                refreshButton
            }
            .padding(14)
        } else {
            SettingsRow(title: "Облако") {
                Picker("", selection: $draft.remote) {
                    Text("Не выбрано").tag("")
                    ForEach(remotes, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .pointing()
                refreshButton
            }
        }
        SettingsRow(title: "Папка в облаке") {
            TextField("", text: $draft.remotePath, prompt: Text("backups"))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
        }
    }

    private var refreshButton: some View {
        Button {
            Task { remotes = await model.rcloneRemotes() }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderlessPointing)
        .hoverTip("Обновить список облаков")
    }
}

struct DestinationCopies: View {
    @Environment(AppModel.self) private var model
    let destination: Destination

    @State private var usedBytes: Int64?
    @State private var snapshots: [UUID: [Snapshot]]?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Копии")
                Spacer()
                if let usedBytes { Text(Texts.bytes(usedBytes)) }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            if sources.isEmpty {
                note("Сюда пока не бэкапится ни один источник.")
            } else if let snapshots {
                SettingsCard {
                    ForEach(sources) { source in
                        CopiesRow(source: source, destination: destination, snapshots: snapshots[source.id] ?? [])
                    }
                }
            } else if model.condition(of: destination).isConnected {
                ProgressView().controlSize(.small).padding(.horizontal, 14)
            } else {
                note("Не подключено — копии не видны.")
            }
        }
        .task(id: LoadKey(destination: destination, isConnected: model.condition(of: destination).isConnected, runs: model.runs.count)) {
            await load()
        }
    }

    private struct LoadKey: Equatable {
        let destination: Destination
        let isConnected: Bool
        let runs: Int
    }

    private var sources: [Source] {
        model.config.sources.filter { $0.destinationIds.contains(destination.id) }
    }

    private func note(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).padding(.horizontal, 14)
    }

    private func load() async {
        guard await model.isAvailable(destination) else {
            snapshots = nil
            usedBytes = nil
            return
        }
        var loaded: [UUID: [Snapshot]] = [:]
        for source in sources {
            loaded[source.id] = await model.snapshots(of: source, in: destination).sorted { $0.date > $1.date }
        }
        snapshots = loaded
        usedBytes = await model.usedBytes(destination)
    }
}

struct CopiesRow: View {
    @Environment(AppModel.self) private var model
    let source: Source
    let destination: Destination
    let snapshots: [Snapshot]

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    SourceIcon(source)
                    Text(source.name).fontWeight(.medium).lineLimit(1)
                    Text(snapshots.isEmpty ? "копий ещё нет" : Texts.copies(snapshots.count))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(Texts.age(snapshots.first?.date))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .opacity(snapshots.isEmpty ? 0 : 1)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plainPointing)
            .disabled(snapshots.isEmpty)
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(snapshots, id: \.self) { snapshot in
                        SnapshotLine(snapshot: snapshot, url: model.localURL(of: snapshot, source: source, in: destination))
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }
}

struct SnapshotLine: View {
    let snapshot: Snapshot
    let url: URL?

    @State private var isHovered = false

    var body: some View {
        HStack {
            Text(Texts.dateTime(snapshot.date))
            Spacer()
            if let url {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderlessPointing)
                .hoverTip("Показать в Finder")
                .opacity(isHovered ? 1 : 0)
            } else {
                Text(snapshot.name).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .font(.callout)
        .padding(.leading, 44)
        .padding(.trailing, 14)
        .frame(height: 26)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
