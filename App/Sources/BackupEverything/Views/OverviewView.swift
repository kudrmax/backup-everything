import BackupCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    let editSource: (Source) -> Void
    let openSources: () -> Void
    let openDestinations: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                OverviewHeader()
                if model.config.destinations.isEmpty {
                    GettingStarted(openDestinations: openDestinations, openSources: openSources)
                }
                if !model.config.sources.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(model.config.sources.enumerated()), id: \.element.id) { index, source in
                            if index > 0 { Divider() }
                            SourceRow(source: source, destinationSlots: destinationSlots, edit: { editSource(source) })
                        }
                    }
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                if !model.config.destinations.isEmpty {
                    DestinationStrip()
                }
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Обзор")
    }

    private var destinationSlots: Int {
        model.config.sources.map { model.config.destinations(of: $0).count }.max() ?? 0
    }
}

struct OverviewHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: StatusStyle.symbol(model.report.overall))
                .font(.title)
                .foregroundStyle(StatusStyle.color(model.report.overall))
            Text(Texts.headline(model.report))
                .font(.title2.weight(.semibold))
            Spacer()
            if model.isWorking {
                ProgressView().controlSize(.small)
                Text(model.currentSourceName ?? "проверка…").foregroundStyle(.blue)
            }
            Button("Запустить всё", systemImage: "play.fill") {
                Task { await model.runAll() }
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.isWorking)
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
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct SourceRow: View {
    @Environment(AppModel.self) private var model
    private static let badgeWidth: CGFloat = 18
    private static let badgeSpacing: CGFloat = 12

    let source: Source
    let destinationSlots: Int
    let edit: () -> Void

    @State private var isHovered = false
    @State private var showsInstructions = false
    @State private var shownError: String?

    var body: some View {
        let status = model.status(of: source)
        let stage = model.stage(of: source)
        HStack(spacing: 14) {
            stateIcon(status, stage)
                .frame(width: 18)
            HStack(spacing: 9) {
                SourceIcon(icon: source.icon, symbol: StatusStyle.symbol(for: source.kind))
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(source.name)
                        .fontWeight(.medium)
                        .foregroundStyle(source.enabled ? .primary : .secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .hoverTip(source.description)
                    note(status, stage)
                }
            }
            if canPickUp(status) {
                Button("Забрать") {
                    Task { await model.confirmPickup(source) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.isWorking)
            }
            Spacer(minLength: 8)
            hoverActions
            timeColumn
                .font(.callout)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
            HStack(spacing: Self.badgeSpacing) {
                ForEach(destinations) { destination in
                    DestinationBadge(source: source, destination: destination)
                        .frame(width: Self.badgeWidth)
                }
            }
            .frame(width: slotsWidth, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(isHovered ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .sheet(isPresented: Binding(get: { shownError != nil }, set: { if !$0 { shownError = nil } })) {
            ErrorSheet(title: source.name, message: shownError ?? "")
        }
        .sheet(isPresented: $showsInstructions) {
            InstructionsSheet(title: source.name, text: source.instructions)
        }
    }

    private var destinations: [Destination] {
        model.config.destinations(of: source)
    }

    private var slotsWidth: CGFloat {
        let slots = CGFloat(max(destinationSlots, 1))
        return slots * Self.badgeWidth + (slots - 1) * Self.badgeSpacing + 6
    }

    @ViewBuilder
    private func stateIcon(_ status: SourceStatus, _ stage: SourceStage?) -> some View {
        if let stage {
            if stage == .queued {
                Image(systemName: "hourglass").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        } else if !source.enabled {
            Image(systemName: "pause.circle").foregroundStyle(.secondary)
        } else {
            Image(systemName: StatusStyle.symbol(status.severity))
                .foregroundStyle(StatusStyle.color(status.severity))
        }
    }

    @ViewBuilder
    private func note(_ status: SourceStatus, _ stage: SourceStage?) -> some View {
        if let stage {
            Text(stageText(stage))
                .font(.callout)
                .foregroundStyle(.blue)
                .lineLimit(1)
        } else if let note = status.note, let error = status.errorMessage {
            Button {
                shownError = error
            } label: {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverTip("Нажми, чтобы открыть и скопировать ошибку")
        } else if let note = status.note {
            Text(note)
                .font(.callout)
                .foregroundStyle(status.severity == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
                .hoverTip(status.text)
        }
    }

    private func stageText(_ stage: SourceStage) -> String {
        let text = Texts.stage(stage, destinationName: deliveringName(stage))
        guard let status = model.runStatus(of: source) else { return text }
        return "\(text.trimmingCharacters(in: CharacterSet(charactersIn: "…"))) · \(status)"
    }

    @ViewBuilder
    private var timeColumn: some View {
        if let startedAt = model.runStartedAt(of: source) {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(startedAt)
                Text(Texts.duration(elapsed))
                    .foregroundStyle(.blue)
                    .hoverTip(RunTiming.tip(elapsed: elapsed, usual: model.usualDuration(of: source)))
            }
        } else {
            Text(Texts.age(model.lastBackup(of: source)))
                .foregroundStyle(.secondary)
                .hoverTip(timeDetails)
        }
    }

    private func canPickUp(_ status: SourceStatus) -> Bool {
        guard case let .filesFound(_, _, downloading) = status else { return false }
        return !downloading && model.stage(of: source) == nil
    }

    private var hoverActions: some View {
        HStack(spacing: 6) {
            if !source.isManualExport {
                Button {
                    Task { await model.runNow(source) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .disabled(model.isWorking || destinations.isEmpty)
                .help("Запустить")
            }
            Menu {
                if !source.instructions.isEmpty {
                    Button("Инструкция") { showsInstructions = true }
                }
                if let error = model.status(of: source).errorMessage {
                    Button("Показать ошибку") { shownError = error }
                }
                Button("Изменить", action: edit)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .opacity(isHovered ? 1 : 0)
    }

    private func deliveringName(_ stage: SourceStage) -> String? {
        guard case let .delivering(destinationId) = stage else { return nil }
        return model.config.destination(destinationId)?.name
    }

    private var timeDetails: String {
        var lines = ["Последний бэкап: \(model.lastBackup(of: source).map(Texts.dateTime) ?? "ещё не было")"]
        if source.enabled {
            if let due = model.nextDue(of: source) {
                let prefix = source.isManualExport ? "Экспорт пора делать" : "Следующий"
                lines.append("\(prefix): \(due <= Date() ? "уже пора" : Texts.dateTime(due))")
            } else {
                lines.append("Следующий: только вручную")
            }
        }
        if let size = model.lastSize(of: source) {
            lines.append("Размер копии: \(Texts.bytes(size))")
        }
        return lines.joined(separator: "\n")
    }
}

struct DestinationBadge: View {
    @Environment(AppModel.self) private var model
    let source: Source
    let destination: Destination

    var body: some View {
        Image(systemName: StatusStyle.symbol(for: destination.kind))
            .foregroundStyle(color)
            .symbolEffect(.pulse, isActive: isDelivering)
            .overlay(alignment: .bottomTrailing) {
                if let mark, !isDelivering {
                    Image(systemName: mark)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(color)
                        .background(Circle().fill(.background.secondary).padding(-1))
                        .offset(x: 5, y: 4)
                }
            }
            .hoverTip(details)
    }

    private var isDelivering: Bool {
        model.stage(of: source) == .delivering(destinationId: destination.id)
    }

    private var state: DeliveryState {
        DeliveryState.of(
            lastOutcome: model.lastDelivery(of: source, to: destination)?.outcome,
            isWaiting: model.isWaiting(source, for: destination)
        )
    }

    private var color: Color {
        if isDelivering { return .blue }
        switch state {
        case .delivered: return .green
        case .failed: return .red
        case .waiting: return .orange
        case .none: return .secondary
        }
    }

    private var mark: String? {
        switch state {
        case .delivered: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .waiting: "clock.fill"
        case .none: nil
        }
    }

    private var details: String {
        if isDelivering { return "\(destination.name)\nзаписывается…" }
        let last = model.lastDelivery(of: source, to: destination)
        switch state {
        case .delivered:
            return "\(destination.name)\nдоставлено \(last.map { Texts.relative($0.date) } ?? "")"
        case .failed:
            let message = last.map { Texts.outcome($0.outcome) } ?? "ошибка"
            return "\(destination.name)\n\(message)\nповтор позже"
        case .waiting:
            return "\(destination.name)\nждёт подключения"
        case .none:
            return "\(destination.name)\nкопий ещё нет"
        }
    }
}

struct DestinationStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 18) {
            ForEach(model.config.destinations) { destination in
                let condition = model.condition(of: destination)
                HStack(spacing: 6) {
                    DestinationIcon(destination: destination, marksAvailable: false)
                    Text(condition.problem.map { "\(destination.name) · \($0)" } ?? destination.name)
                        .padding(.leading, condition.isConnected ? 0 : 3)
                        .foregroundStyle(style(condition))
                }
                .font(.callout)
                .hoverTip(DestinationDetails.text(of: destination, model: model))
            }
        }
        .padding(.horizontal, 4)
    }

    private func style(_ condition: DestinationCondition) -> AnyShapeStyle {
        switch condition {
        case .available: AnyShapeStyle(.secondary)
        case .offline: AnyShapeStyle(.tertiary)
        case .needsConnection, .unreachable: AnyShapeStyle(.orange)
        }
    }
}

@MainActor
enum DestinationDetails {
    static func text(of destination: Destination, model: AppModel) -> String {
        var lines = [model.condition(of: destination).isConnected ? "Доступно" : "Сейчас не подключено"]
        let waiting = model.waitingSources(for: destination)
        if let caughtUp = model.lastCaughtUp(destination) {
            lines.append("Получило всё: \(Texts.relative(caughtUp))")
        }
        lines.append(waiting.isEmpty ? "Ничего не ждёт доставки" : "Ждут доставки: \(waiting.map(\.name).joined(separator: ", "))")
        return lines.joined(separator: "\n")
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
