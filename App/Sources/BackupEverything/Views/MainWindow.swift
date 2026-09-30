import SwiftUI

struct MainWindow: View {
    static let id = "main"

    enum Section: String, CaseIterable, Identifiable {
        case overview
        case sources
        case destinations
        case history
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: "Обзор"
            case .sources: "Источники"
            case .destinations: "Назначения"
            case .history: "История"
            case .settings: "Настройки"
            }
        }

        var symbol: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .sources: "tray.and.arrow.up"
            case .destinations: "externaldrive"
            case .history: "clock.arrow.circlepath"
            case .settings: "gearshape"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @AppStorage("section") private var storedSection = Section.overview.rawValue

    private var section: Binding<Section?> {
        Binding(
            get: { Section(rawValue: storedSection) ?? .overview },
            set: { storedSection = ($0 ?? .overview).rawValue }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: section) { section in
                Label(section.title, systemImage: section.symbol)
                    .pointing()
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                if let problem = model.problem {
                    ProblemBanner(text: problem)
                }
                switch section.wrappedValue ?? .overview {
                case .overview:
                    OverviewView(
                        editSource: { source in
                            UserDefaults.standard.set(source.id.uuidString, forKey: "selectedSource")
                            storedSection = Section.sources.rawValue
                        },
                        openSources: { storedSection = Section.sources.rawValue },
                        openDestinations: { storedSection = Section.destinations.rawValue }
                    )
                case .sources: SourcesView()
                case .destinations: DestinationsView()
                case .history: HistoryView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 860, minHeight: 520)
        .buttonStyle(.automaticPointing)
        .task { await model.tick() }
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }
}

struct ProblemBanner: View {
    @Environment(AppModel.self) private var model
    let text: String

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(text)
            Spacer()
            Button("Скрыть") { model.dismissProblem() }
        }
        .padding(10)
        .background(.red.opacity(0.1))
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
    }
}
