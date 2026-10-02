import Foundation
import os

public struct ProcessResult: Sendable, Equatable {
    public var exitCode: Int32
    /// The signal that stopped the process; `exitCode` is then 128 + signal, as the shell shows it.
    public var signal: Int32?
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(exitCode: Int32, signal: Int32? = nil, stdout: String = "", stderr: String = "", timedOut: Bool = false) {
        self.exitCode = exitCode
        self.signal = signal
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

public protocol ProcessRunner: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult

    /// `onSpawn` learns the started process: its group is the command with everything it spawned.
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?,
        onOutput: (@Sendable (String) -> Void)?,
        onSpawn: (@Sendable (ProcessIdentity) -> Void)?
    ) async throws -> ProcessResult
}

public extension ProcessRunner {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?,
        onOutput: (@Sendable (String) -> Void)?,
        onSpawn: (@Sendable (ProcessIdentity) -> Void)?
    ) async throws -> ProcessResult {
        try await run(executable: executable, arguments: arguments, environment: environment, timeout: timeout, onOutput: onOutput)
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?
    ) async throws -> ProcessResult {
        try await run(executable: executable, arguments: arguments, environment: environment, timeout: timeout, onOutput: nil)
    }
}

/// Runs each command in its own process group. Timeout, task cancellation and quitting the app stop the whole group.
public struct SystemProcessRunner: ProcessRunner {
    private static let killGracePeriod: TimeInterval = 5

    private let groups: ProcessGroups

    public init(groups: ProcessGroups = .shared) {
        self.groups = groups
    }

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        try await run(executable: executable, arguments: arguments, environment: environment, timeout: timeout, onOutput: onOutput, onSpawn: nil)
    }

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?,
        onOutput: (@Sendable (String) -> Void)?,
        onSpawn: (@Sendable (ProcessIdentity) -> Void)?
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let group = SpawnedGroup()
        let launch = Launch(executable: executable, arguments: arguments, environment: environment, timeout: timeout, onOutput: onOutput, onSpawn: onSpawn)
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async { [groups] in
                    continuation.resume(with: Result { try Self.runBlocking(launch, group: group, groups: groups) })
                }
            }
        } onCancel: {
            group.stop(grace: Self.killGracePeriod)
        }
        try Task.checkCancellation()
        return result
    }

    private struct Launch {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let timeout: TimeInterval?
        let onOutput: (@Sendable (String) -> Void)?
        let onSpawn: (@Sendable (ProcessIdentity) -> Void)?
    }

    private static func runBlocking(_ launch: Launch, group: SpawnedGroup, groups: ProcessGroups) throws -> ProcessResult {
        // Registered before the start, so that a quit beginning at any moment either refuses the command or stops it.
        guard groups.insert(group) else { throw CancellationError() }
        defer { groups.remove(group) }
        let fileManager = FileManager.default
        let capture = fileManager.temporaryDirectory.appendingPathComponent("process-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: capture, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: capture) }

        let stdoutURL = capture.appendingPathComponent("stdout")
        let stderrURL = capture.appendingPathComponent("stderr")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, stdoutURL.path, O_WRONLY | O_APPEND, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, stderrURL.path, O_WRONLY | O_APPEND, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes, 0)
        // A GCD thread blocks signals; without a reset the child inherits the mask and ignores SIGTERM.
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)
        var defaulted = sigset_t()
        sigfillset(&defaulted)
        posix_spawnattr_setsigdefault(&attributes, &defaulted)
        posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        ))

        let mergedEnvironment = ProcessInfo.processInfo.environment.merging(launch.environment) { _, new in new }
        let argv = ([launch.executable.path] + launch.arguments).map { strdup($0) } + [nil]
        let envp = mergedEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var spawned: pid_t = 0
        let spawnCode = posix_spawn(&spawned, launch.executable.path, &fileActions, &attributes, argv, envp)
        guard spawnCode == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: spawnCode) ?? .ENOENT)
        }
        group.attach(spawned)
        if let onSpawn = launch.onSpawn, let identity = ProcessIdentity.of(spawned) {
            onSpawn(identity)
        }

        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let deadline = launch.timeout.map { timeout in
            let terminate = DispatchWorkItem {
                timedOut.withLock { $0 = true }
                group.stop(grace: killGracePeriod)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: terminate)
            return terminate
        }
        let watcher = launch.onOutput.map { OutputWatcher(file: stdoutURL, report: $0) }
        watcher?.start()
        var exited = siginfo_t()
        while waitid(P_PID, id_t(spawned), &exited, WEXITED | WNOWAIT) == -1, errno == EINTR {}
        deadline?.cancel()
        // The leader is not reaped yet, so the group id is still ours: whatever the stopped command left running dies with it.
        if group.wasStopped { group.signal(SIGKILL) }
        group.detach()
        groups.remove(group)
        var status: Int32 = 0
        while waitpid(spawned, &status, 0) == -1, errno == EINTR {}
        watcher?.stop()
        // What a command stopped by quitting reports is not its result: nobody is left to record it as a failure.
        if group.wasStopped, groups.isQuitting { throw CancellationError() }
        let signal = status & 0x7f
        let exitCode = signal == 0 ? (status >> 8) & 0xff : 128 + signal

        return ProcessResult(
            exitCode: exitCode,
            signal: signal == 0 ? nil : signal,
            stdout: text(of: stdoutURL),
            stderr: text(of: stderrURL),
            timedOut: timedOut.withLock { $0 }
        )
    }

    /// Bytes that are not UTF-8 (a file name in another encoding, binary progress) must not cost the whole output.
    private static func text(of file: URL) -> String {
        (try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

private final class OutputWatcher: Sendable {
    private static let interval: TimeInterval = 0.5
    private static let tailLength: UInt64 = 4096

    private let file: URL
    private let report: @Sendable (String) -> Void
    private let lastLine = OSAllocatedUnfairLock(initialState: "")
    private let timer: DispatchSourceTimer

    init(file: URL, report: @escaping @Sendable (String) -> Void) {
        self.file = file
        self.report = report
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "backup-everything.output-watcher"))
    }

    func start() {
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
    }

    func stop() {
        timer.cancel()
        check()
    }

    private func check() {
        guard let line = latestLine() else { return }
        let isNew = lastLine.withLock { last in
            guard last != line else { return false }
            last = line
            return true
        }
        if isNew { report(line) }
    }

    private func latestLine() -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > Self.tailLength ? size - Self.tailLength : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}
