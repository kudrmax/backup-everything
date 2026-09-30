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
            if let problem = model.problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
            if let source = model.runningSource {
                RunningLine(source: source)
            } else if model.isWorking {
                MenuLineLayout {
                    ProgressView().controlSize(.small)
                } content: {
                    Text("Идёт проверка…").foregroundStyle(.blue)
                }
            }
            ForEach(model.menuLines) { line in
                MenuLineRow(line: line)
            }
            if model.menuLines.isEmpty, !model.isWorking {
                MenuLineLayout {
                    Image(systemName: StatusStyle.symbol(.ok)).foregroundStyle(StatusStyle.color(.ok))
                } content: {
                    Text("Всё в порядке").fontWeight(.medium)
                    if let latest = model.latestBackup {
                        Text("последний бэкап \(Texts.relative(latest))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

struct MenuLineLayout<Mark: View, Content: View>: View {
    @ViewBuilder let mark: Mark
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            mark.frame(width: 16)
            content
            Spacer(minLength: 0)
        }
    }
}

struct MenuLineRow: View {
    @Environment(AppModel.self) private var model
    let line: MenuLine

    var body: some View {
        MenuLineLayout {
            Image(systemName: StatusStyle.symbol(line.severity)).foregroundStyle(StatusStyle.color(line.severity))
        } content: {
            icon
            Text(line.name).fontWeight(.medium).lineLimit(1).layoutPriority(1)
            Text(line.text)
                .font(.callout)
                .foregroundStyle(line.severity == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .lineLimit(1)
            if line.canPickUp, case let .source(source) = line.subject {
                Button("Забрать") {
                    Task { await model.confirmPickup(source) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.isWorking)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch line.subject {
        case let .source(source): SourceIcon(source, size: 14)
        case let .destination(destination): SourceIcon(icon: nil, symbol: StatusStyle.symbol(for: destination.kind), size: 14)
        }
    }
}

struct RunningLine: View {
    @Environment(AppModel.self) private var model
    let source: Source

    var body: some View {
        MenuLineLayout {
            ProgressView().controlSize(.small)
        } content: {
            SourceIcon(source, size: 14)
            Text(source.name).fontWeight(.medium).lineLimit(1).layoutPriority(1)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(progress(at: context.date))
                    .font(.callout)
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func progress(at date: Date) -> String {
        let elapsed = model.runStartedAt(of: source).map { Texts.duration(date.timeIntervalSince($0)) }
        return [model.runStatus(of: source), elapsed].compactMap { $0 }.joined(separator: " · ")
    }
}
