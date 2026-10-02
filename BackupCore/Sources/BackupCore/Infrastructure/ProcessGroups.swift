import Darwin
import Foundation
import os

/// A process told apart from a later one that reuses its pid: the pid together with the moment the process started.
public struct ProcessIdentity: Codable, Sendable, Equatable {
    public let pid: Int32
    public let startSeconds: Int
    public let startMicroseconds: Int32

    public init(pid: Int32, startSeconds: Int, startMicroseconds: Int32) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }

    public static func of(_ pid: pid_t) -> ProcessIdentity? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&query, u_int(query.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_stat != SZOMB else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return ProcessIdentity(pid: pid, startSeconds: started.tv_sec, startMicroseconds: started.tv_usec)
    }

    public var isRunning: Bool {
        Self.of(pid) == self
    }

    /// Stops a group left by an earlier launch of the app. Only while its leader is still the same process:
    /// a group without it may already be someone else's.
    public func terminateGroup(grace: TimeInterval) {
        guard isRunning else { return }
        Self.signalGroup(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while isRunning, Date() < deadline {
            usleep(50_000)
        }
        if isRunning { Self.signalGroup(pid, SIGKILL) }
    }

    /// `kill(-pid)` for 0 or 1 would reach the app's own group or every process of the user, so only a real leader is signalled.
    @discardableResult
    static func signalGroup(_ leader: pid_t, _ signal: Int32) -> Bool {
        guard leader > 1 else { return false }
        return kill(-leader, signal) == 0
    }
}

/// Tells whether the app has begun to quit: from then on, whatever its stopped commands report is not a result.
public protocol QuitSignal: Sendable {
    var isQuitting: Bool { get }
}

/// A process group the app started and has not reaped yet: until then its id cannot belong to anyone else.
final class SpawnedGroup: Sendable {
    private struct State {
        var pid: pid_t?
        var stopped = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var wasStopped: Bool {
        state.withLock { $0.stopped }
    }

    func attach(_ pid: pid_t) {
        let stopped = state.withLock { state in
            state.pid = pid
            return state.stopped
        }
        if stopped { ProcessIdentity.signalGroup(pid, SIGTERM) }
    }

    func terminate() {
        state.withLock { $0.stopped = true }
        signal(SIGTERM)
    }

    /// Asks the group to stop; it is killed if it still runs after the grace period.
    func stop(grace: TimeInterval) {
        terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in signal(SIGKILL) }
    }

    func signal(_ signal: Int32) {
        state.withLock { state in
            if let pid = state.pid { ProcessIdentity.signalGroup(pid, signal) }
        }
    }

    /// The leader has exited: the group's id is about to be released.
    func detach() {
        state.withLock { $0.pid = nil }
    }
}

/// Commands the app is running right now. On quit they are stopped with the app instead of living on unattended.
public final class ProcessGroups: QuitSignal {
    static let quitGrace: TimeInterval = 1

    public static let shared: ProcessGroups = {
        let groups = ProcessGroups()
        atexit { ProcessGroups.shared.terminateAll(grace: ProcessGroups.quitGrace) }
        return groups
    }()

    private struct State {
        var running: [ObjectIdentifier: SpawnedGroup] = [:]
        var quitting = false
    }

    /// Requests to quit from outside the app: `kill`, logging out, Ctrl-C in Terminal.
    public static let terminationSignals = [SIGTERM, SIGHUP, SIGINT]

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let signalSources = OSAllocatedUnfairLock<[any DispatchSourceSignal]>(uncheckedState: [])

    public init() {}

    /// Left to the system, a request to quit from outside ends the app at once, without `atexit`, and its commands would run
    /// on unattended. Handled, it ends the app the way Quit does: the commands are stopped first.
    public func installTerminationHandlers(
        signals: [Int32] = ProcessGroups.terminationSignals,
        exit: @escaping @Sendable (Int32) -> Void = { Darwin.exit($0) }
    ) {
        let queue = DispatchQueue(label: "backup-everything.termination")
        let sources = signals.map { number -> any DispatchSourceSignal in
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [self] in
                terminateAll(grace: Self.quitGrace)
                exit(0)
            }
            source.resume()
            return source
        }
        signalSources.withLockUnchecked { $0 += sources }
    }

    public var count: Int {
        state.withLock { $0.running.count }
    }

    public var isQuitting: Bool {
        state.withLock { $0.quitting }
    }

    /// The app quits: every running command is stopped, and no new one is let in.
    public func terminateAll(grace: TimeInterval) {
        let groups = state.withLock { state in
            state.quitting = true
            return Array(state.running.values)
        }
        groups.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(grace)
        while count > 0, Date() < deadline {
            usleep(20_000)
        }
        state.withLock { $0.running.values.forEach { $0.signal(SIGKILL) } }
    }

    /// `false` once the app is quitting: such a group is not kept and is to be stopped right away.
    func insert(_ group: SpawnedGroup) -> Bool {
        state.withLock { state in
            guard !state.quitting else { return false }
            state.running[ObjectIdentifier(group)] = group
            return true
        }
    }

    func remove(_ group: SpawnedGroup) {
        state.withLock { _ = $0.running.removeValue(forKey: ObjectIdentifier(group)) }
    }
}
