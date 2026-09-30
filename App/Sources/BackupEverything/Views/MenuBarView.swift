import BackupCore
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var launchesAtLogin = LoginItem.isEnabled
    @State private var loginProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let problem = model.problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
            if !model.report.items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(model.report.items.enumerated()), id: \.offset) { _, item in
                        AttentionRow(item: item)
                    }
                }
            }
            Divider()
            Button("Запустить всё сейчас", systemImage: "play.fill") {
                Task { await model.runAll() }
            }
            .disabled(model.isWorking)
            Button("Открыть окно", systemImage: "macwindow") {
                openWindow(id: MainWindow.id)
                NSApp.activate(ignoringOtherApps: true)
            }
            Toggle("Запускать при входе", isOn: $launchesAtLogin)
                .onChange(of: launchesAtLogin) { _, enabled in
                    loginProblem = LoginItem.setEnabled(enabled)
                    launchesAtLogin = LoginItem.isEnabled
                }
            if let loginProblem {
                Text(loginProblem).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Button("Выйти", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
        .buttonStyle(.plain)
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: StatusStyle.symbol(model.report.overall))
                .foregroundStyle(StatusStyle.color(model.report.overall))
            Text(Texts.overall(model.report.overall)).font(.headline)
            Spacer()
            if model.isWorking {
                ProgressView().controlSize(.small)
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
                Text(text.detail).font(.callout).foregroundStyle(.secondary)
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
