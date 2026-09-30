import AppKit
import BackupCore
import Foundation

@MainActor
final class BackgroundDriver {
    private static let eventDebounce: TimeInterval = 2
    private static let settleRecheck: TimeInterval = ManualExportInbox.settleSeconds + 3
    private static let timerTolerance: TimeInterval = 60

    private let model: AppModel
    private var timer: Timer?
    private var watchers: [String: FolderWatcher] = [:]
    private var pendingTick: Task<Void, Never>?
    private var pendingRecheck: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        model.onChange = { [weak self] in self?.reschedule() }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.didMountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleTick(after: Self.eventDebounce) }
            })
        }
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
        scheduleTick(after: Self.eventDebounce)
        pendingRecheck?.cancel()
        pendingRecheck = Task { [model] in
            try? await Task.sleep(for: .seconds(Self.settleRecheck))
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
        timer?.invalidate()
        timer = nil
        guard let date else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleTick(after: 0) }
        }
        timer.tolerance = Self.timerTolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
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
            watchers[path] = FolderWatcher(url: URL(fileURLWithPath: path)) { [weak self] in
                self?.folderChanged()
            }
        }
    }
}
