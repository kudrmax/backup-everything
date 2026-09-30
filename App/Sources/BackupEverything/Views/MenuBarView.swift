import BackupCore
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("section") private var storedSection = MainWindow.Section.overview.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Открыть окно", systemImage: "macwindow", action: showWindow)
            Divider()
            status
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    storedSection = MainWindow.Section.overview.rawValue
                    showWindow()
                }
            Divider()
            Button("Запустить всё сейчас", systemImage: "play.fill") {
                Task { await model.runAll() }
            }
            .disabled(model.isWorking)
            Divider()
            Button("Выйти", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
        .buttonStyle(.plain)
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }

    private func showWindow() {
        openWindow(id: MainWindow.id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: model.headlineSymbol)
                    .foregroundStyle(model.headlineColor)
                Text(model.headline).font(.headline)
                Spacer()
                if model.isWorking {
                    ProgressView().controlSize(.small)
                }
            }
            if model.isWorking {
                Text(model.currentRunLine ?? "Идёт проверка…")
                    .font(.callout)
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let problem = model.problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
            ForEach(Array(model.report.items.enumerated()), id: \.offset) { _, item in
                AttentionRow(item: item)
            }
        }
    }
}

struct AttentionRow: View {
    @Environment(AppModel.self) private var model
    let item: AttentionItem

    var body: some View {
        let text = Texts.attention(item, config: model.config)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: StatusStyle.symbol(item.severity))
                .foregroundStyle(StatusStyle.color(item.severity))
            VStack(alignment: .leading, spacing: 2) {
                Text(text.title).fontWeight(.medium)
                Text(text.detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                if let source = pickupSource {
                    Button("Готово, забрать") {
                        Task { await model.confirmPickup(source) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.isWorking)
                    .padding(.top, 2)
                }
            }
        }
    }

    private var pickupSource: Source? {
        guard case let .filesAwaitingPickup(sourceId, _, _, downloadInProgress) = item, !downloadInProgress else { return nil }
        return model.config.source(sourceId)
    }
}
