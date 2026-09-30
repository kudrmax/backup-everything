import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct ChainPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let cloud = Destination(name: "Cloud", kind: .localFolder(path: "/tmp/cloud"))

    private var claude: Source {
        Source(
            name: "Claude",
            slug: "claude",
            kind: .steps(steps: [
                SourceStep(name: "Запросить экспорт", kind: .manual(instructions: "Скачайте манифест.", watchPath: "~/Downloads", filePattern: "manifest-*.json", includeInCopy: false)),
                SourceStep(name: "Скачать архивы", kind: .command(command: "true", timeoutSeconds: 60)),
            ]),
            schedule: .monthly,
            destinationIds: [cloud.id],
            instructions: "Экспорт в два шага.",
            createdAt: now
        )
    }

    private var folder: Source {
        Source(name: "Obsidian", slug: "obsidian", kind: .folder(path: "~/Obsidian", excludes: []), schedule: .daily, createdAt: now)
    }

    @Test func positionIsShownOnlyForStepChains() {
        #expect(ChainPosition.label(of: folder, chain: nil) == nil)
        #expect(ChainPosition.label(of: claude, chain: nil) == "шаг 1 из 2")
        #expect(ChainPosition.label(of: claude, chain: ChainState(stepIndex: 1, startedAt: now, stepEnteredAt: now)) == "шаг 2 из 2")
        #expect(ChainPosition.label(of: claude, chain: ChainState(stepIndex: 2, startedAt: now, stepEnteredAt: now)) == "шаг 2 из 2")
        #expect(ChainPosition.label(index: 1, count: 3) == "шаг 2 из 3")
    }

    @Test func noteStartsWithThePosition() {
        let stuck = ChainState(stepIndex: 1, startedAt: now, stepEnteredAt: now, failure: "x")
        #expect(ChainPosition.note("пора сделать экспорт", of: claude, chain: nil, status: .exportDue) == "шаг 1 из 2 · пора сделать экспорт")
        #expect(ChainPosition.note("нет архивов", of: claude, chain: stuck, status: .failed("x")) == "шаг 2 из 2 · нет архивов")
        #expect(ChainPosition.note("1 файл · 2 Б · идёт загрузка", of: claude, chain: nil, status: .filesFound(count: 1, bytes: 2, downloading: true)) == "шаг 1 из 2 · 1 файл · 2 Б · идёт загрузка")
        #expect(ChainPosition.note(nil, of: claude, chain: nil, status: .ok) == nil)
        #expect(ChainPosition.note("выключен", of: folder, chain: nil, status: .disabled) == "выключен")
    }

    @Test func positionIsNotAddedToNotesUnrelatedToTheChain() {
        #expect(ChainPosition.note("не выбрано, куда бэкапить", of: claude, chain: nil, status: .noDestinations) == "не выбрано, куда бэкапить")
        #expect(ChainPosition.note("диск отвалился", of: claude, chain: nil, status: .failed("диск отвалился")) == "диск отвалился")
        #expect(ChainPosition.note("давно не было бэкапа", of: claude, chain: nil, status: .overdue) == "давно не было бэкапа")
    }

    @Test func runButtonIsOfferedOnlyWhenItWouldDoSomething() {
        let source = claude
        let waitingForManifest: ChainState? = nil
        let readyToAssemble = ChainState(stepIndex: 2, startedAt: now, stepEnteredAt: now)
        let interrupted = ChainState(stepIndex: 1, startedAt: now, stepEnteredAt: now)
        let failed = ChainState(stepIndex: 1, startedAt: now, stepEnteredAt: now, failure: "x")
        var commandFirst = source
        commandFirst.kind = .steps(steps: source.steps.reversed())

        #expect(ChainPosition.canRunNow(folder, chain: nil))
        #expect(!ChainPosition.canRunNow(source, chain: waitingForManifest))
        #expect(ChainPosition.canRunNow(source, chain: interrupted))
        #expect(ChainPosition.canRunNow(source, chain: failed))
        #expect(ChainPosition.canRunNow(source, chain: readyToAssemble))
        #expect(ChainPosition.canRunNow(commandFirst, chain: nil))
        #expect(!ChainPosition.canRunNow(commandFirst, chain: interrupted))
    }

    @Test func menuLineCarriesThePosition() {
        let source = claude
        let message = "Команда завершилась с кодом 1. нет архивов"
        let config = Config(sources: [source], destinations: [cloud])
        var state = AppState()
        state.updateSource(source.id) { $0.chain = ChainState(stepIndex: 1, startedAt: now, stepEnteredAt: now, failure: message) }
        let report = StatusReport(items: [.runFailed(sourceId: source.id, message: message)])

        let lines = MenuLines.of(config: config, state: state, report: report, unavailable: [])
        #expect(lines.map(\.text) == ["шаг 2 из 2 · нет архивов"])
        #expect(lines.first?.severity == .error)
    }

    @Test func guideJoinsTheSourceInstructionWithItsManualSteps() {
        #expect(SourceGuide.text(for: claude) == """
        Экспорт в два шага.

        **Шаг 1. Запросить экспорт**

        Скачайте манифест.
        """)
        var plain = folder
        plain.instructions = "Укажите путь."
        #expect(SourceGuide.text(for: plain) == "Укажите путь.")
        #expect(SourceGuide.text(for: folder).isEmpty)
    }
}
