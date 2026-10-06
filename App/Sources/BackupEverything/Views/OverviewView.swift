import BackupCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    let editSource: (Source) -> Void
    let openSources: () -> Void
    let openDestinations: () -> Void

    @AppStorage("overviewOrder") private var order = OverviewOrder.manual

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                OverviewHeader(order: $order)
                if model.config.destinations.isEmpty {
                    GettingStarted(openDestinations: openDestinations, openSources: openSources)
                }
                if !model.config.sources.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(sortedSources.enumerated()), id: \.element.id) { index, source in
                            if index > 0 { Divider() }
                            SourceRow(source: source, destinationSlots: destinationSlots, edit: { editSource(source) })
                        }
                    }
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .animation(.snappy, value: sortedSources.map(\.id))
                }
                if !model.config.destinations.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        DestinationStrip(openSettings: { destination in
                            UserDefaults.standard.set(destination.id.uuidString, forKey: "selectedDestination")
                            openDestinations()
                        })
                        WorkingSpaceLine()
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Overview")
    }

    private var sortedSources: [Source] {
        order.sorted(model.config.sources) { model.nextDue(of: $0) }
    }

    private var destinationSlots: Int {
        model.config.sources.map { model.config.destinations(of: $0).count }.max() ?? 0
    }
}

struct OverviewHeader: View {
    @Environment(AppModel.self) private var model
    @Binding var order: OverviewOrder

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.headlineSymbol)
                .font(.title)
                .foregroundStyle(model.headlineColor)
            Text(model.headline)
                .font(.title2.weight(.semibold))
            Spacer()
            if model.isWorking {
                ProgressView().controlSize(.small)
                Text(model.currentSourceName ?? "checking…").foregroundStyle(.blue)
            }
            Picker(selection: $order) {
                ForEach(OverviewOrder.allCases) { Text($0.title).tag($0) }
            } label: {
                Label("Order", systemImage: "arrow.up.arrow.down")
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .pointing()
            .hoverTip("Source order")
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.tick() }
            }
            .labelStyle(.titleAndIcon)
            .hoverTip(Texts.refreshTip)
            Button("Back up everything again", systemImage: "play.fill") {
                Task { await model.runAll() }
            }
            .labelStyle(.titleAndIcon)
            .hoverTip(Texts.runAllTip)
        }
    }
}

struct GettingStarted: View {
    let openDestinations: () -> Void
    let openSources: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Getting started").font(.headline)
            Text("1. Add a destination — a folder, an external disk or a cloud.")
            Text("2. Add sources from templates and choose where to back them up.")
            HStack {
                Button("Add destination", action: openDestinations).buttonStyle(.borderedProminentPointing)
                Button("Go to sources", action: openSources)
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
                SourceIcon(icon: source.icon, symbol: StatusStyle.symbol(for: source))
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
            .frame(maxWidth: .infinity, alignment: .leading)
            if isHovered {
                hoverActions
                    .transition(.opacity)
            }
            if canPickUp(status) {
                Button("Pick up") {
                    Task { await model.confirmPickup(source) }
                }
                .buttonStyle(.borderedProminentPointing)
                .controlSize(.small)
                .disabled(model.isWorking)
            }
            timeColumn
                .font(.callout)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
            nextColumn
                .font(.callout)
                .monospacedDigit()
                .frame(width: 96, alignment: .leading)
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
        .onTapGesture(perform: edit)
        .pointing()
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { isHovered = inside } }
        .sheet(isPresented: Binding(get: { shownError != nil }, set: { if !$0 { shownError = nil } })) {
            ErrorSheet(title: source.name, message: shownError ?? "")
        }
        .sheet(isPresented: $showsInstructions) {
            InstructionsSheet(title: source.name, text: SourceGuide.text(for: source))
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
        switch SourceMark.of(stage: stage, isEnabled: source.enabled, status: status) {
        case .working:
            ProgressView().controlSize(.small)
        case let .symbol(name):
            Image(systemName: name).foregroundStyle(.secondary)
        case let .severity(severity):
            Image(systemName: StatusStyle.symbol(severity))
                .foregroundStyle(StatusStyle.color(severity))
        }
    }

    @ViewBuilder
    private func note(_ status: SourceStatus, _ stage: SourceStage?) -> some View {
        if let stage {
            Text(stageText(stage))
                .font(.callout)
                .foregroundStyle(.blue)
                .lineLimit(1)
                .truncationMode(.tail)
                .hoverTip(stageText(stage))
        } else if let note = status.note, let error = status.errorMessage {
            Button {
                shownError = error
            } label: {
                Text(positioned(note))
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plainPointing)
            .hoverTip("Click to open and copy the error")
        } else if let note = status.note {
            Text(positioned(note))
                .font(.callout)
                .foregroundStyle(status.severity == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
                .hoverTip(status.text)
        }
    }

    private func positioned(_ note: String) -> String {
        ChainPosition.note(note, of: source, chain: model.chain(of: source.id), status: model.status(of: source)) ?? note
    }

    private func stageText(_ stage: SourceStage) -> String {
        RunProgressText.note(
            stage,
            of: source,
            destinationName: deliveringName(stage),
            status: model.runStatus(of: source),
            step: model.runStep(of: source)
        )
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

    @ViewBuilder
    private var nextColumn: some View {
        if model.runStartedAt(of: source) == nil,
           let note = NextBackup.note(source, nextDue: model.nextDue(of: source), isWaiting: model.isWaitingForPerson(source)) {
            Text("→ \(note)")
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .hoverTip("Next backup: \(NextBackup.detail(source, nextDue: model.nextDue(of: source), isWaiting: model.isWaitingForPerson(source)))")
        } else {
            Color.clear
        }
    }

    private func canPickUp(_ status: SourceStatus) -> Bool {
        status.offersPickUp && model.stage(of: source) == nil
    }

    private var hoverActions: some View {
        let chain = model.chain(of: source.id)
        return HStack(spacing: 4) {
            if model.isWaitingForPerson(source) {
                action("Cancel: stop waiting", symbol: "xmark.circle") {
                    Task { await model.cancelWaiting(source) }
                }
            } else if ChainPosition.canRunNow(source, chain: chain) {
                action(ChainPosition.runTitle(source, chain: chain), symbol: "play.fill") {
                    Task { await model.runNow(source) }
                }
                .disabled(destinations.isEmpty)
            }
            if chain != nil {
                action("Start over", symbol: "arrow.counterclockwise") {
                    Task { await model.restartChain(source) }
                }
                .disabled(model.isWorking)
            }
            if !SourceGuide.text(for: source).isEmpty {
                action("Instructions", symbol: "book") { showsInstructions = true }
            }
            if let original = SourceLinks.original(of: source) {
                action("Show original in Finder", symbol: "folder") { model.reveal(original) }
            }
            copyAction
            action("Edit", symbol: "pencil", perform: edit)
        }
        .buttonStyle(.borderlessPointing)
    }

    @ViewBuilder
    private var copyAction: some View {
        let places = SourceLinks.copies(of: source, config: model.config, state: model.state)
        if places.count == 1, let place = places.first {
            action("Open copy", symbol: "archivebox") {
                if let folder = place.folder { model.reveal(folder) }
            }
            .disabled(place.folder == nil)
            .hoverTip(place.tip)
        } else if places.count > 1 {
            Menu {
                ForEach(places) { place in
                    Button(place.menuTitle) {
                        if let folder = place.folder { model.reveal(folder) }
                    }
                    .disabled(place.folder == nil)
                }
            } label: {
                Image(systemName: "archivebox")
            }
            .menuStyle(.button)
            .buttonStyle(.borderlessPointing)
            .menuIndicator(.hidden)
            .fixedSize()
            .hoverTip("Show copy in Finder")
        }
    }

    private func action(_ title: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
        }
        .hoverTip(title)
    }

    private func deliveringName(_ stage: SourceStage) -> String? {
        guard case let .delivering(destinationId) = stage else { return nil }
        return model.config.destination(destinationId)?.name
    }

    private var timeDetails: String {
        RunProgressText.times(source, lastBackup: model.lastBackup(of: source), nextDue: model.nextDue(of: source), size: model.lastSize(of: source))
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
        state.mark
    }

    private var details: String {
        DeliveryText.details(
            destinationName: destination.name,
            isWriting: isDelivering,
            state: state,
            last: model.lastDelivery(of: source, to: destination)
        ) {
            ConnectReminder.waitingLine(
                elsewhere: model.isCoveredElsewhere(source, for: destination),
                otherDestinations: model.otherCopies(of: source, besides: destination).map(\.name)
            )
        }
    }
}

struct DestinationStrip: View {
    @Environment(AppModel.self) private var model
    let openSettings: (Destination) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(model.config.destinations) { destination in
                let condition = model.condition(of: destination)
                Button {
                    open(destination, isConnected: condition.isConnected)
                } label: {
                    HStack(spacing: 6) {
                        DestinationIcon(destination: destination, showsMarks: false)
                        Text(title(of: destination, condition: condition))
                            .foregroundStyle(style(condition))
                    }
                    .font(.callout)
                }
                .hoverTip(DestinationDetails.text(of: destination, model: model) + "\n\n" + action(for: destination, isConnected: condition.isConnected))
            }
        }
        .buttonStyle(.borderlessPointing)
    }

    private func title(of destination: Destination, condition: DestinationCondition) -> String {
        DestinationLink.title(of: destination, used: model.destinationUsage[destination.id], condition: condition)
    }

    private func open(_ destination: Destination, isConnected: Bool) {
        if let folder = DestinationLink.finderFolder(of: destination, isConnected: isConnected) {
            model.reveal(folder)
        } else {
            openSettings(destination)
        }
    }

    private func action(for destination: Destination, isConnected: Bool) -> String {
        DestinationLink.actionTip(for: destination, isConnected: isConnected)
    }

    private func style(_ condition: DestinationCondition) -> AnyShapeStyle {
        switch condition {
        case .available: AnyShapeStyle(.secondary)
        case .offline: AnyShapeStyle(.tertiary)
        case .needsConnection, .unreachable, .otherDisk, .diskNotConfirmed: AnyShapeStyle(.orange)
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
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
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

struct WorkingSpaceLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let need = model.workingSpace
        if need.bytes > 0 {
            let isShort = WorkingSpace.isShort(need: need, free: model.freeSpace)
            Label(WorkingSpace.line(need: need, free: model.freeSpace), systemImage: isShort ? "exclamationmark.triangle.fill" : "internaldrive")
                .font(.callout)
                .foregroundStyle(isShort ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 4)
                .hoverTip(WorkingSpace.details(need: need))
        }
    }
}
