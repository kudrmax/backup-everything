import AppKit
import BackupCore
import Foundation
import Testing
@testable import BackupEverything

@MainActor
private final class FakeModel: BackgroundModel {
    var config = Config()
    var onChange: () -> Void = {}
    var onConfigEdited: () -> Void = {}
    var wake: Date?
    private(set) var ticks = 0

    func tick() async {
        ticks += 1
    }

    func nextWake() async -> Date? {
        wake
    }
}

@MainActor
private final class FakeEvents: SystemEvents {
    private var handler: (@MainActor () -> Void)?

    func onWakeOrMount(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    func fire() {
        handler?()
    }
}

@MainActor
private final class FakeTimer: WakeTimer {
    private(set) var scheduledAt: Date?
    private(set) var cancels = 0
    private var fire: (@MainActor () -> Void)?

    func schedule(at date: Date, _ fire: @escaping @MainActor () -> Void) {
        scheduledAt = date
        self.fire = fire
    }

    func cancel() {
        cancels += 1
        scheduledAt = nil
        fire = nil
    }

    func ring() {
        fire?()
    }
}

@MainActor
private final class FakeWatcher: FolderWatching {
    let url: URL
    let onChange: @MainActor () -> Void
    private(set) var isStopped = false

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func stop() {
        isStopped = true
    }
}

@MainActor
private final class WatcherLog {
    var created: [FakeWatcher] = []
    var unavailable: Set<String> = []

    func make(_ url: URL, _ onChange: @escaping @MainActor () -> Void) -> (any FolderWatching)? {
        guard !unavailable.contains(url.path) else { return nil }
        let watcher = FakeWatcher(url: url, onChange: onChange)
        created.append(watcher)
        return watcher
    }

    var active: [String] {
        created.filter { !$0.isStopped }.map(\.url.path).sorted()
    }
}

@MainActor
struct BackgroundDriverTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let model = FakeModel()
    private let events = FakeEvents()
    private let timer = FakeTimer()
    private let watchers = WatcherLog()

    private func driver(debounce: TimeInterval = 0.05, settle: TimeInterval = 0.3) -> BackgroundDriver {
        BackgroundDriver(
            model: model,
            events: events,
            timer: timer,
            delays: BackgroundDriver.Delays(eventDebounce: debounce, settleRecheck: settle),
            makeWatcher: watchers.make
        )
    }

    private func exportSource(_ name: String, in folder: String, enabled: Bool = true) -> Source {
        Source(
            name: name,
            slug: name.lowercased(),
            steps: [.file("\(name.lowercased())-*.zip", in: folder)],
            schedule: .monthly,
            enabled: enabled,
            createdAt: now
        )
    }

    /// Lets everything already scheduled run, then reports how many checks there were.
    private func ticksAfter(_ seconds: TimeInterval) async -> Int {
        try? await Task.sleep(for: .seconds(seconds))
        return model.ticks
    }

    @Test func checksRightAfterLaunch() async {
        let driver = driver()
        driver.start()
        #expect(await eventually { model.ticks == 1 })
        #expect(await ticksAfter(0.2) == 1)
    }

    @Test func burstOfWakeAndMountEventsGivesOneCheck() async {
        let driver = driver()
        driver.start()
        #expect(await eventually { model.ticks == 1 })
        events.fire()
        events.fire()
        events.fire()
        #expect(await eventually { model.ticks == 2 })
        #expect(await ticksAfter(0.2) == 2)
    }

    @Test func eventChecksOnlyAfterItCalmsDown() async {
        let driver = driver(debounce: 1)
        driver.start()
        #expect(await eventually { model.ticks == 1 })
        events.fire()
        #expect(await ticksAfter(0.2) == 1)
        #expect(await eventually { model.ticks == 2 })
    }

    @Test func savedSettingsAreCheckedRightAway() async {
        let driver = driver()
        driver.start()
        #expect(await eventually { model.ticks == 1 })
        model.onConfigEdited()
        #expect(await eventually { model.ticks == 2 })
    }

    @Test func timerIsArmedForTheNextWakeAndChecksWhenItFires() async {
        let driver = driver()
        driver.start()
        #expect(await eventually { model.ticks == 1 })
        let wake = now.addingTimeInterval(3600)
        model.wake = wake
        model.onChange()
        #expect(await eventually { timer.scheduledAt == wake })
        timer.ring()
        #expect(await eventually { model.ticks == 2 })
    }

    @Test func nothingDueLeavesNoTimer() async {
        let driver = driver()
        driver.start()
        model.wake = now
        model.onChange()
        #expect(await eventually { timer.scheduledAt == now })
        model.wake = nil
        let cancels = timer.cancels
        model.onChange()
        #expect(await eventually { timer.cancels > cancels })
        #expect(timer.scheduledAt == nil)
    }

    @Test func watchesTheFoldersOfEnabledExportsOnly() async {
        let driver = driver()
        driver.start()
        model.config = Config(sources: [
            exportSource("Google", in: "/tmp/exports"),
            exportSource("Claude", in: "/tmp/exports"),
            exportSource("Telegram", in: "/tmp/telegram", enabled: false),
            Source(name: "Notes", slug: "notes", steps: [.folder("/tmp/notes")], schedule: .daily, createdAt: now),
        ])
        model.onChange()
        #expect(watchers.active == ["/tmp/exports"])
    }

    @Test func folderNoLongerNeededIsNoLongerWatched() async {
        let driver = driver()
        driver.start()
        model.config = Config(sources: [exportSource("Google", in: "/tmp/google"), exportSource("Claude", in: "/tmp/claude")])
        model.onChange()
        model.config.sources.removeLast()
        model.onChange()
        #expect(watchers.active == ["/tmp/google"])
        #expect(watchers.created.count == 2)
    }

    @Test func tildeInTheFolderIsExpanded() async {
        let driver = driver()
        driver.start()
        model.config = Config(sources: [exportSource("Google", in: "~/Downloads")])
        model.onChange()
        #expect(watchers.active == [AppPaths.expand("~/Downloads").path])
    }

    @Test func folderThatCannotBeWatchedYetIsTriedAgainOnTheNextChange() async {
        let driver = driver()
        driver.start()
        watchers.unavailable = ["/tmp/later"]
        model.config = Config(sources: [exportSource("Google", in: "/tmp/later")])
        model.onChange()
        #expect(watchers.active.isEmpty)
        watchers.unavailable = []
        model.onChange()
        #expect(watchers.active == ["/tmp/later"])
    }

    @Test func fileLandingChecksSoonAndAgainOnceItSettles() async {
        let driver = driver(debounce: 0.05, settle: 0.8)
        driver.start()
        #expect(await eventually { model.ticks == 1 })
        model.config = Config(sources: [exportSource("Google", in: "/tmp/exports")])
        model.onChange()
        let watcher = watchers.created[0]
        watcher.onChange()
        watcher.onChange()
        #expect(await eventually { model.ticks == 2 })
        #expect(await ticksAfter(0.1) == 2)
        #expect(await eventually { model.ticks == 3 })
        #expect(await ticksAfter(0.3) == 3)
    }

    @Test func realFolderWatcherReportsAFileLanding() async throws {
        let temp = try TemporaryFolder()
        let driver = BackgroundDriver(
            model: model,
            events: events,
            timer: timer,
            delays: BackgroundDriver.Delays(eventDebounce: 0.05, settleRecheck: 60)
        )
        driver.start()
        #expect(await eventually { model.ticks == 1 })
        model.config = Config(sources: [exportSource("Google", in: temp.url.path)])
        model.onChange()
        try temp.file("google-1.zip")
        #expect(await eventually { model.ticks == 2 })
    }

    @Test func standardDelaysWaitForAFileToSettle() {
        let delays = BackgroundDriver.Delays()
        #expect(delays.eventDebounce == 2)
        #expect(delays.settleRecheck > ManualExportInbox.settleSeconds)
    }
}

@MainActor
struct RunLoopWakeTimerTests {
    @Test func firesAtTheGivenMoment() async {
        let timer = RunLoopWakeTimer(tolerance: 0)
        var fired = 0
        timer.schedule(at: Date().addingTimeInterval(0.05)) { fired += 1 }
        #expect(await eventually { fired == 1 })
    }

    @Test func cancelledTimerNeverFires() async throws {
        let timer = RunLoopWakeTimer(tolerance: 0)
        var fired = 0
        timer.schedule(at: Date().addingTimeInterval(0.05)) { fired += 1 }
        timer.cancel()
        try await Task.sleep(for: .milliseconds(200))
        #expect(fired == 0)
    }

    @Test func newScheduleReplacesTheOldOne() async throws {
        let timer = RunLoopWakeTimer(tolerance: 0)
        var fired: [String] = []
        timer.schedule(at: Date().addingTimeInterval(0.05)) { fired.append("old") }
        timer.schedule(at: Date().addingTimeInterval(0.1)) { fired.append("new") }
        #expect(await eventually { !fired.isEmpty })
        try await Task.sleep(for: .milliseconds(100))
        #expect(fired == ["new"])
    }
}

@MainActor
struct WorkspaceEventsTests {
    @Test func wakeAndMountBothReachTheHandler() async {
        let events = WorkspaceEvents()
        var calls = 0
        events.onWakeOrMount { calls += 1 }
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.didMountNotification, object: nil)
        #expect(await eventually { calls == 2 })
    }
}
