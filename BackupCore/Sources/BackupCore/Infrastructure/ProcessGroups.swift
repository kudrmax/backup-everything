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
        kill(-pid, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while isRunning, Date() < deadline {
            usleep(50_000)
        }
        if isRunning { kill(-pid, SIGKILL) }
    }
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
        if stopped { kill(-pid, SIGTERM) }
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
            if let pid = state.pid { kill(-pid, signal) }
        }
    }

    /// The leader has exited: the group's id is about to be released.
    func detach() {
        state.withLock { $0.pid = nil }
    }
}

/// Commands the app is running right now. On quit they are stopped with the app instead of living on unattended.
public final class ProcessGroups: Sendable {
    public static let shared: ProcessGroups = {
        let groups = ProcessGroups()
        atexit { ProcessGroups.shared.terminateAll(grace: 1) }
        return groups
    }()

    private let running = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: SpawnedGroup]())

    public init() {}

    public var count: Int {
        running.withLock { $0.count }
    }

    public func terminateAll(grace: TimeInterval) {
        let groups = running.withLock { Array($0.values) }
        groups.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(grace)
        while count > 0, Date() < deadline {
            usleep(20_000)
        }
        running.withLock { $0.values.forEach { $0.signal(SIGKILL) } }
    }

    func insert(_ group: SpawnedGroup) {
        running.withLock { $0[ObjectIdentifier(group)] = group }
    }

    func remove(_ group: SpawnedGroup) {
        running.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(group)) }
    }
}
