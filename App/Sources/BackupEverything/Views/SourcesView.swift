import BackupCore
import SwiftUI

struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("selectedSource") private var storedSelection = ""
    @State private var session = EditorSession<SourceDraft>()

    var body: some View {
        EditorLayout(items: model.config.sources, selection: $session.selection, reorder: { ids in Task { await model.orderSources(ids) } }) { source in
            HStack(spacing: 8) {
                SourceIcon(source)
                Text(source.name)
            }
            .foregroundStyle(source.enabled ? .primary : .secondary)
        } addMenu: {
            Section("From a template") {
                ForEach(model.templates) { template in
                    Button(template.name) { start(model.newSource(from: template), as: nil) }
                }
            }
            Section("Empty — start with") {
                ForEach(SourceStart.allCases) { choice in
                    Button(choice.title) { start(model.newSource(from: nil), as: choice) }
                }
            }
        } detail: {
            if let draft = session.draft {
                SourceEditor(
                    draft: Binding(get: { session.draft ?? draft }, set: { session.draft = $0 }),
                    isNew: session.isNew,
                    onSave: save,
                    onDelete: delete,
                    onCancel: cancel
                )
                .id(draft.id)
            } else {
                EmptyState(symbol: "tray.and.arrow.up", title: "No sources yet", message: "Add the first one with the “Add” button on the left.")
            }
        }
        .navigationTitle("Sources")
        .onAppear {
            session.appear(remembered: UUID(uuidString: storedSelection), in: model.config.sources)
        }
        .onChange(of: session.selection) { _, id in
            if let id = session.selectionChanged(to: id, in: model.config.sources) { storedSelection = id.uuidString }
        }
    }

    private func start(_ source: Source, as choice: SourceStart?) {
        session.start(SourceDraft(source, startingWith: choice))
    }

    private func save(_ source: Source) {
        Task {
            await model.save(source)
            session.saved(source)
        }
    }

    private func delete(_ source: Source) {
        Task {
            await model.delete(source)
            session.showFirst(of: model.config.sources)
        }
    }

    private func cancel() {
        session.cancel(in: model.config.sources)
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
            EditorHeader(name: $draft.name, prompt: "Name", isNameEditable: isNew) {
                Button {
                    if let file = IconImporter.chooseFile(), let icon = model.importIcon(from: file) { draft.icon = icon }
                } label: {
                    SourceIcon(icon: draft.icon, symbol: symbol, size: 22)
                }
                .buttonStyle(.plainPointing)
                .hoverTip("Choose icon")
            } accessory: {
                Toggle("Enabled", isOn: $draft.enabled)
                    .toggleStyle(.switch)
                    .pointing()
                    .controlSize(.small)
                    .labelsHidden()
                    .hoverTip(draft.enabled ? "Enabled" : "Disabled")
                if !isNew || draft.icon != nil {
                    Menu {
                        if draft.icon != nil {
                            Button("Remove icon") { draft.icon = nil }
                        }
                        if !isNew {
                            Button("Delete source…", role: .destructive) { confirmsDeletion = true }
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
            TextField("", text: $draft.description, prompt: Text("Description: what is backed up here"), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 40)
                .padding(.top, -8)
                .padding(.bottom, 4)
        } content: {
            SettingsSection(title: "How often and where", isProminent: true) {
                SettingsRow(title: "How often") {
                    Picker("", selection: $draft.schedule) {
                        ForEach(Schedule.allCases, id: \.self) { Text(Texts.schedule($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .pointing()
                }
                if !isNew, let saved = model.config.source(draft.id) {
                    SettingsRow(title: "Next backup") {
                        Text(NextBackup.detail(saved, nextDue: model.nextDue(of: saved), isWaiting: model.isWaitingForPerson(saved)))
                            .foregroundStyle(.secondary)
                    }
                }
                SettingsRow(title: "Where") {
                    if model.config.destinations.isEmpty {
                        Text("add a destination first").foregroundStyle(.secondary)
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
                SettingsRow(title: "Save space", tip: SpaceSaving.tip) {
                    if let note = spaceSaving.note {
                        Text(note).foregroundStyle(.secondary)
                    }
                    Toggle("", isOn: Binding(get: { draft.savesSpace && spaceSaving.isPossible }, set: { draft.savesSpace = $0 }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .pointing()
                        .disabled(!spaceSaving.isPossible)
                }
            }
            StepsEditor(steps: $draft.steps, currentIndex: isNew ? nil : model.chain(of: draft.id)?.stepIndex)
            SettingsSection(title: "More") {
                DisclosureRow(title: "Keep copies", summary: RetentionPlan.summary(draft.retention)) {
                    RetentionEditor(rules: $draft.retention, showCopies: isNew ? nil : {
                        let source = draft.build()
                        Task { previews = await model.retentionPreview(for: source) }
                    })
                }
                DisclosureRow(title: "Instructions: one-time setup", summary: draft.instructionsSummary) {
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
        .confirmationDialog("Delete source “\(draft.name)”?", isPresented: $confirmsDeletion) {
            Button("Delete source", role: .destructive) { onDelete(draft.build()) }
        } message: {
            Text("Copies already made in the destinations will stay where they are.")
        }
    }

    private var symbol: String {
        draft.symbol
    }

    private var spaceSaving: SpaceSaving {
        let chosen = model.config.destinations.filter { draft.destinationIds.contains($0.id) }
        return SpaceSaving.of(chosen, sharing: model.destinationSharing)
    }

    private var instructionsEditor: some View {
        TextEditor(text: $draft.instructions)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: 120)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private var conflictWarning: String? {
        guard draft.watchesFiles else { return nil }
        return Texts.maskOverlap(model.maskConflicts(for: draft.build()))
    }

    private func membership(of id: UUID) -> Binding<Bool> {
        Binding(
            get: { draft.destinationIds.contains(id) },
            set: { draft.setDestination(id, included: $0) }
        )
    }
}

struct RetentionPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let previews: [RetentionPreview]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keeping copies").font(.title3.weight(.semibold))
            if previews.isEmpty {
                Text("The source has no destinations selected.").foregroundStyle(.secondary)
            }
            List {
                ForEach(previews) { preview in
                    Section(preview.destination.name) {
                        if preview.kept.isEmpty && preview.doomed.isEmpty {
                            Text("No copies yet, or the destination is unavailable.").foregroundStyle(.secondary)
                        }
                        ForEach(preview.kept, id: \.self) { snapshot in
                            Label(Texts.dateTime(snapshot.date), systemImage: "checkmark.circle").foregroundStyle(.primary)
                        }
                        ForEach(preview.doomed, id: \.self) { snapshot in
                            Label("\(Texts.dateTime(snapshot.date)) — will be deleted", systemImage: "trash").foregroundStyle(.red)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 460)
    }
}
