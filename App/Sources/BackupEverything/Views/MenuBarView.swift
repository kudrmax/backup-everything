import BackupCore
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("section") private var storedSection = MainWindow.Section.overview.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Open window", systemImage: "macwindow", action: showWindow)
            separator
            status
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .tappableRow {
                    storedSection = MainWindow.Section.overview.rawValue
                    showWindow()
                }
            separator
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.tick() }
            }
            .hoverTip(Texts.refreshTip)
            Button("Back up everything again", systemImage: "play.fill") {
                Task { await model.runAll() }
            }
            .hoverTip(Texts.runAllTip)
            separator
            Button("Quit", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
        .buttonStyle(.menuRow)
        .padding(6)
        .frame(width: 340, alignment: .leading)
    }

    private var separator: some View {
        Divider().padding(.horizontal, 8).padding(.vertical, 2)
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
                    Text("Checking…").foregroundStyle(.blue)
                }
            }
            ForEach(model.menuLines) { line in
                MenuLineRow(line: line)
            }
            if model.isAllGood, !model.isWorking {
                MenuLineLayout {
                    Image(systemName: StatusStyle.symbol(.ok)).foregroundStyle(StatusStyle.color(.ok))
                } content: {
                    Text("All good").fontWeight(.medium)
                    if let latest = model.latestBackup {
                        Text("last backup \(Texts.relative(latest))")
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
                Button("Pick up") {
                    Task { await model.confirmPickup(source) }
                }
                .buttonStyle(.borderedProminentPointing)
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
        RunProgressText.menuLine(step: model.runStep(of: source), status: model.runStatus(of: source), startedAt: model.runStartedAt(of: source), at: date)
    }
}
