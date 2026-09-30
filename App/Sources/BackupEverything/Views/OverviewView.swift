import BackupCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    let openSources: () -> Void
    let openDestinations: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summary
                if model.config.destinations.isEmpty {
                    GettingStarted(openDestinations: openDestinations, openSources: openSources)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(model.config.sources) { source in
                        SourceCard(source: source)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Обзор")
        .toolbar {
            Button("Запустить всё", systemImage: "play.fill") {
                Task { await model.runAll() }
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.isWorking)
        }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Image(systemName: StatusStyle.symbol(model.report.overall))
                .font(.title)
                .foregroundStyle(StatusStyle.color(model.report.overall))
            Text(Texts.overall(model.report.overall)).font(.title2.weight(.semibold))
            if model.isWorking {
                ProgressView().controlSize(.small)
                Text("Идёт бэкап…").foregroundStyle(.secondary)
            }
        }
    }
}

struct GettingStarted: View {
    let openDestinations: () -> Void
    let openSources: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("С чего начать").font(.headline)
            Text("1. Добавьте назначение — папку, внешний диск или облако.")
            Text("2. Добавьте источники из шаблонов и выберите, куда их бэкапить.")
            HStack {
                Button("Добавить назначение", action: openDestinations).buttonStyle(.borderedProminent)
                Button("Перейти к источникам", action: openSources)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SourceCard: View {
    @Environment(AppModel.self) private var model
    let source: Source
    @State private var showsInstructions = false

    var body: some View {
        let status = model.status(of: source)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: StatusStyle.symbol(for: source.kind)).foregroundStyle(.secondary)
                Text(source.name).font(.headline).lineLimit(1)
                Spacer()
                Image(systemName: StatusStyle.symbol(status.severity))
                    .foregroundStyle(source.enabled ? StatusStyle.color(status.severity) : .secondary)
            }
            Text(status.text)
                .font(.callout)
                .foregroundStyle(status.severity == .ok ? .secondary : StatusStyle.color(status.severity))
                .lineLimit(3)
            VStack(alignment: .leading, spacing: 3) {
                fact("Последний бэкап", model.lastRun(of: source).map { Texts.relative($0) } ?? "—")
                fact("Следующий", nextText)
            }
            if !destinations.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(destinations) { destination in
                        let waiting = model.isWaiting(source, for: destination)
                        Label {
                            Text(waiting ? "\(destination.name) — ждёт" : destination.name)
                        } icon: {
                            Image(systemName: waiting ? "clock" : StatusStyle.symbol(for: destination.kind))
                        }
                        .font(.callout)
                        .foregroundStyle(waiting ? .orange : .secondary)
                    }
                }
            }
            HStack {
                primaryButton(status)
                if !source.instructions.isEmpty {
                    Button("Инструкция") { showsInstructions = true }
                }
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .sheet(isPresented: $showsInstructions) {
            InstructionsSheet(title: source.name, text: source.instructions)
        }
    }

    private var destinations: [Destination] {
        model.config.destinations(of: source)
    }

    private var nextText: String {
        guard source.enabled else { return "—" }
        guard let due = model.nextDue(of: source) else { return Texts.schedule(.manual) }
        if due <= Date() { return source.isManualExport ? "ждёт экспорта" : "при ближайшей возможности" }
        return Texts.relative(due)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text("\(title):").foregroundStyle(.secondary)
            Text(value)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func primaryButton(_ status: SourceStatus) -> some View {
        if source.isManualExport {
            if case let .filesFound(_, _, downloading) = status {
                Button("Готово, забрать") {
                    Task { await model.confirmPickup(source) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(downloading || model.isWorking)
            }
        } else {
            Button("Запустить") {
                Task { await model.runNow(source) }
            }
            .disabled(model.isWorking || destinations.isEmpty)
        }
    }
}

struct InstructionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            ScrollView {
                Text(rendered)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 380)
    }

    private var rendered: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
