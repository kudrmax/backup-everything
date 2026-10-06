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
            steps: [
                SourceStep(name: "Request export", kind: .file(instructions: "Download the manifest.", watchPath: "~/Downloads", filePattern: "manifest-*.json", fileMode: .single, includeInCopy: false, removeOriginal: true)),
                SourceStep(name: "Download archives", kind: .command(command: "true", timeoutSeconds: 60)),
            ],
            schedule: .monthly,
            destinationIds: [cloud.id],
            instructions: "Export in two steps.",
            createdAt: now
        )
    }

    private var folder: Source {
        Source(name: "Obsidian", slug: "obsidian", steps: [.folder("~/Obsidian", excludes: [])], schedule: .daily, createdAt: now)
    }

    @Test func positionIsShownOnlyForStepChains() {
        #expect(ChainPosition.label(of: folder, chain: nil) == nil)
        #expect(ChainPosition.label(of: claude, chain: nil) == "step 1 of 2")
        #expect(ChainPosition.label(of: claude, chain: ChainState(stepIndex: 1, startedAt: now, stepEnteredAt: now)) == "step 2 of 2")
        #expect(ChainPosition.label(of: claude, chain: ChainState(stepIndex: 2, startedAt: now, stepEnteredAt: now)) == "step 2 of 2")
        #expect(ChainPosition.label(index: 1, count: 3) == "step 2 of 3")
    }

    @Test func noteStartsWithThePosition() {
        let stuck = ChainState(stepIndex: 1, startedAt: now, stepEnteredAt: now, failure: "x")
        #expect(ChainPosition.note("time to export", of: claude, chain: nil, status: .exportDue) == "step 1 of 2 · time to export")
        #expect(ChainPosition.note("no archives", of: claude, chain: stuck, status: .failed("x")) == "step 2 of 2 · no archives")
        #expect(ChainPosition.note("1 file · 2 B · downloading", of: claude, chain: nil, status: .filesFound(count: 1, bytes: 2, downloading: true)) == "step 1 of 2 · 1 file · 2 B · downloading")
        #expect(ChainPosition.note("waiting for a file", of: claude, chain: nil, status: .waiting) == "step 1 of 2 · waiting for a file")
        #expect(ChainPosition.note(nil, of: claude, chain: nil, status: .ok) == nil)
        #expect(ChainPosition.note("disabled", of: folder, chain: nil, status: .disabled) == "disabled")
    }

    @Test func positionIsNotAddedToNotesUnrelatedToTheChain() {
        #expect(ChainPosition.note("no destination chosen", of: claude, chain: nil, status: .noDestinations) == "no destination chosen")
        #expect(ChainPosition.note("disk dropped off", of: claude, chain: nil, status: .failed("disk dropped off")) == "disk dropped off")
        #expect(ChainPosition.note("no backup for a long time", of: claude, chain: nil, status: .overdue(nil)) == "no backup for a long time")
    }

    @Test func runButtonIsOfferedOnlyWhenItWouldDoSomething() {
        let source = claude
        let waitingForManifest: ChainState? = nil
        let readyToAssemble = ChainState(stepIndex: 2, startedAt: now, stepEnteredAt: now)
        let interrupted = ChainState(stepIndex: 1, startedAt: now, stepEnteredAt: now)
        let failed = ChainState(stepIndex: 1, startedAt: now, stepEnteredAt: now, failure: "x")
        var commandFirst = source
        commandFirst.steps = source.steps.reversed()

        #expect(ChainPosition.canRunNow(folder, chain: nil))
        #expect(ChainPosition.canRunNow(source, chain: waitingForManifest))
        #expect(ChainPosition.canRunNow(source, chain: interrupted))
        #expect(ChainPosition.canRunNow(source, chain: failed))
        #expect(ChainPosition.canRunNow(source, chain: readyToAssemble))
        #expect(ChainPosition.canRunNow(commandFirst, chain: nil))
        #expect(!ChainPosition.canRunNow(commandFirst, chain: interrupted))
    }

    @Test func menuLineCarriesThePosition() {
        let source = claude
        let message = "Command exited with code 1. no archives"
        let config = Config(sources: [source], destinations: [cloud])
        var state = AppState()
        state.updateSource(source.id) { $0.chain = ChainState(stepIndex: 1, startedAt: now, stepEnteredAt: now, failure: message) }
        let report = StatusReport(items: [.runFailed(sourceId: source.id, message: message)])

        let lines = MenuLines.of(config: config, state: state, report: report, unavailable: [])
        #expect(lines.map(\.text) == ["step 2 of 2 · no archives"])
        #expect(lines.first?.severity == .error)
    }

    @Test func guideJoinsTheSourceInstructionWithItsManualSteps() {
        #expect(SourceGuide.text(for: claude) == """
        Export in two steps.

        **Step 1. Request export**

        Download the manifest.
        """)
        var plain = folder
        plain.instructions = "Enter the path."
        #expect(SourceGuide.text(for: plain) == "Enter the path.")
        #expect(SourceGuide.text(for: folder).isEmpty)
    }

    @Test func runningStepSaysWhatItDoes() {
        #expect(ChainPosition.running(.folder("/Volumes/POCKETBOOK"), status: nil) == "copying files…")
        #expect(ChainPosition.running(.command("true", timeoutSeconds: 60), status: nil) == "running the command…")
        #expect(ChainPosition.running(.command("true", timeoutSeconds: 60), status: "downloaded 2 of 5") == "downloaded 2 of 5")
    }
}
