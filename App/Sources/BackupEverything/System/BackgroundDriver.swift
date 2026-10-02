import AppKit
import BackupCore
import Foundation

/// What the driver needs from the model: when to wake, what to watch, and a way to run the check.
@MainActor
protocol BackgroundModel: AnyObject {
    var config: Config { get }
    var onChange: () -> Void { get set }
    var onConfigEdited: () -> Void { get set }
    func tick() async
    func nextWake() async -> Date?
}

extension AppModel: BackgroundModel {}

@MainActor
protocol SystemEvents {
    func onWakeOrMount(_ handler: @escaping @MainActor () -> Void)
}

@MainActor
final class WorkspaceEvents: SystemEvents {
    private var observers: [NSObjectProtocol] = []

    func onWakeOrMount(_ handler: @escaping @MainActor () -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.didMountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            })
        }
    }
}

@MainActor
protocol WakeTimer {
    func schedule(at date: Date, _ fire: @escaping @MainActor () -> Void)
    func cancel()
}

@MainActor
final class RunLoopWakeTimer: WakeTimer {
    private let tolerance: TimeInterval
    private var timer: Timer?

    init(tolerance: TimeInterval = 60) {
        self.tolerance = tolerance
    }

    func schedule(at date: Date, _ fire: @escaping @MainActor () -> Void) {
        cancel()
        let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { fire() }
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
final class BackgroundDriver: BackgroundDriving {
    typealias WatcherFactory = @MainActor (URL, @escaping @MainActor () -> Void) -> (any FolderWatching)?

    struct Delays {
        /// Wake, mount and edits come in bursts: one check after they calm down.
        var eventDebounce: TimeInterval = 2
        /// A file that has just landed is picked up only once it stops changing, so the folder is checked again after that.
        var settleRecheck: TimeInterval = ManualExportInbox.settleSeconds + 3
    }

    private let model: any BackgroundModel
    private let events: any SystemEvents
    private let timer: any WakeTimer
    private let makeWatcher: WatcherFactory
    private let delays: Delays
    private var watchers: [String: any FolderWatching] = [:]
    private var pendingTick: Task<Void, Never>?
    private var pendingRecheck: Task<Void, Never>?

    init(
        model: any BackgroundModel,
        events: any SystemEvents = WorkspaceEvents(),
        timer: any WakeTimer = RunLoopWakeTimer(),
        delays: Delays = Delays(),
        makeWatcher: @escaping WatcherFactory = { FolderWatcher(url: $0, onChange: $1) }
    ) {
        self.model = model
        self.events = events
        self.timer = timer
        self.delays = delays
        self.makeWatcher = makeWatcher
    }

    func start() {
        model.onChange = { [weak self] in self?.reschedule() }
        model.onConfigEdited = { [weak self, delays] in self?.scheduleTick(after: delays.eventDebounce) }
        events.onWakeOrMount { [weak self, delays] in self?.scheduleTick(after: delays.eventDebounce) }
        scheduleTick(after: 0)
    }

    private func scheduleTick(after delay: TimeInterval) {
        pendingTick?.cancel()
        pendingTick = Task { [model] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await model.tick()
        }
    }

    private func folderChanged() {
        scheduleTick(after: delays.eventDebounce)
        pendingRecheck?.cancel()
        pendingRecheck = Task { [model, delays] in
            try? await Task.sleep(for: .seconds(delays.settleRecheck))
            guard !Task.isCancelled else { return }
            await model.tick()
        }
    }

    private func reschedule() {
        refreshWatchers()
        Task { [weak self, model] in
            let wake = await model.nextWake()
            self?.armTimer(for: wake)
        }
    }

    private func armTimer(for date: Date?) {
        timer.cancel()
        guard let date else { return }
        timer.schedule(at: date) { [weak self] in self?.scheduleTick(after: 0) }
    }

    private func refreshWatchers() {
        var wanted: Set<String> = []
        for source in model.config.sources where source.enabled {
            for file in source.watchedFiles {
                wanted.insert(AppPaths.expand(file.watchPath).path)
            }
        }
        for path in watchers.keys where !wanted.contains(path) {
            watchers.removeValue(forKey: path)?.stop()
        }
        for path in wanted where watchers[path] == nil {
            watchers[path] = makeWatcher(URL(fileURLWithPath: path)) { [weak self] in
                self?.folderChanged()
            }
        }
    }
}
