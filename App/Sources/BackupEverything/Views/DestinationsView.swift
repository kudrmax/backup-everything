import AppKit
import BackupCore
import SwiftUI

struct DestinationsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("selectedDestination") private var storedSelection = ""
    @State private var session = EditorSession<DestinationDraft>()

    var body: some View {
        VStack(spacing: 0) {
            SetupSection()
            if !model.isStorageReady { Divider() }
            list
            if !model.excessCopies.isEmpty { Divider() }
            ExcessCopiesSection()
        }
        .navigationTitle("Destinations")
        .onAppear {
            session.appear(remembered: UUID(uuidString: storedSelection), in: model.config.destinations)
        }
        .onChange(of: session.selection) { _, id in
            if let id = session.selectionChanged(to: id, in: model.config.destinations) { storedSelection = id.uuidString }
        }
    }

    private var list: some View {
        EditorLayout(items: model.config.destinations, selection: $session.selection) { destination in
            HStack(spacing: 11) {
                DestinationIcon(destination: destination).frame(width: 18)
                Text(destination.name)
            }
        } addMenu: {
            Button("Folder or external disk") { start(.localFolder(path: "")) }
        } detail: {
            if let draft = session.draft {
                DestinationEditor(
                    draft: Binding(get: { session.draft ?? draft }, set: { session.draft = $0 }),
                    isNew: session.isNew,
                    onSave: save,
                    onDelete: delete,
                    onCancel: cancel
                )
                .id(draft.id)
            } else {
                EmptyState(symbol: "externaldrive", title: "No destinations yet", message: "Add a folder or disk with the “Add” button on the left.")
            }
        }
    }

    private func start(_ kind: DestinationKind) {
        session.start(DestinationDraft(Destination(name: "", kind: kind)))
    }

    private func save(_ destination: Destination) {
        Task {
            if let saved = await model.save(destination) { session.saved(saved) }
        }
    }

    private func delete(_ destination: Destination) {
        Task {
            guard await model.delete(destination) else { return }
            session.showFirst(of: model.config.destinations)
        }
    }

    private func cancel() {
        session.cancel(in: model.config.destinations)
    }
}

struct DestinationEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: DestinationDraft
    let isNew: Bool
    let onSave: (Destination) -> Void
    let onDelete: (Destination) -> Void
    let onCancel: () -> Void

    @State private var confirmsDeletion = false

    private var saved: Destination? {
        isNew ? nil : model.config.destination(draft.id)
    }

    var body: some View {
        EditorPage {
            EditorHeader(name: $draft.name, prompt: "Name, e.g. External HDD") {
                if let saved {
                    DestinationIcon(destination: saved)
                        .hoverTip(DestinationDetails.text(of: saved, model: model))
                } else {
                    Image(systemName: "externaldrive").foregroundStyle(.secondary)
                }
            } accessory: {
                if let saved {
                    Menu {
                        Button("Delete…", role: .destructive) { confirmsDeletion = true }
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
            if let saved, let explanation = model.condition(of: saved).explanation(destinationName: saved.name) {
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 40)
            }
        } content: {
            SettingsCard {
                localRows
                SettingsRow(title: "Connection") {
                    Picker("", selection: $draft.isPeriodic) {
                        Text("Always connected").tag(false)
                        Text("From time to time").tag(true)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .pointing()
                }
                if draft.isPeriodic {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsRow(title: "Can stay unplugged") {
                            Stepper("up to \(draft.days) \(Texts.plural(draft.days, "day", "days"))", value: $draft.days, in: 1...365)
                            .pointing()
                        }
                        Text(ConnectReminder.settingsExplanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 10)
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
        .confirmationDialog("Delete destination “\(draft.name)”?", isPresented: $confirmsDeletion) {
            Button("Delete destination", role: .destructive) { onDelete(draft.build()) }
        } message: {
            Text("Copies already in this destination will stay where they are. Sources will stop backing up there.")
        }
    }

    private func attention(for destination: Destination) -> String? {
        DestinationAttention.text(problem: model.condition(of: destination).problem, waiting: [])
    }

    @ViewBuilder
    private var localRows: some View {
        SettingsRow(
            title: "Folder",
            tip: "For an external disk, choose a folder on it.\nThe app doesn’t create this folder itself:\nif the disk isn’t connected, the backup just waits."
        ) {
            PathField(path: $draft.path)
        }
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
                Text("Copies")
                Spacer()
                if let usedBytes { Text(Texts.bytes(usedBytes)) }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            if sources.isEmpty {
                note("No source backs up here yet.")
            } else if let snapshots {
                SettingsCard {
                    ForEach(sources) { source in
                        CopiesRow(source: source, destination: destination, snapshots: snapshots[source.id] ?? [])
                    }
                }
            } else if model.condition(of: destination).isConnected {
                ProgressView().controlSize(.small).padding(.horizontal, 14)
            } else {
                note(model.condition(of: destination).copiesNote)
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
        model.sources(backingUpTo: destination)
    }

    private func note(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).padding(.horizontal, 14)
    }

    private func load() async {
        snapshots = await model.copies(in: destination)
        usedBytes = snapshots == nil ? nil : await model.usedBytes(destination)
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
                    Text(snapshots.isEmpty ? "no copies yet" : Texts.copies(snapshots.count))
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
                .hoverTip("Show in Finder")
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
