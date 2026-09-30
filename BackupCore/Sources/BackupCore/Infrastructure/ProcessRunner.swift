import Foundation
import os

public struct ProcessResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false) {
        self.exitCode = exitCode
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
}

public extension ProcessRunner {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?
    ) async throws -> ProcessResult {
        try await run(executable: executable, arguments: arguments, environment: environment, timeout: timeout, onOutput: nil)
    }
}

public struct SystemProcessRunner: ProcessRunner {
    private static let killGracePeriod: TimeInterval = 5

    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result {
                    try Self.runBlocking(
                        executable: executable,
                        arguments: arguments,
                        environment: environment,
                        timeout: timeout,
                        onOutput: onOutput
                    )
                })
            }
        }
    }

    private static func runBlocking(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?,
        onOutput: (@Sendable (String) -> Void)?
    ) throws -> ProcessResult {
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
        // Поток GCD блокирует сигналы; без сброса потомок унаследует маску и не отреагирует на SIGTERM.
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)
        var defaulted = sigset_t()
        sigfillset(&defaulted)
        posix_spawnattr_setsigdefault(&attributes, &defaulted)
        posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        ))

        let mergedEnvironment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = mergedEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var spawned: pid_t = 0
        let spawnCode = posix_spawn(&spawned, executable.path, &fileActions, &attributes, argv, envp)
        guard spawnCode == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: spawnCode) ?? .ENOENT)
        }
        let processGroup = spawned

        let timedOut = OSAllocatedUnfairLock(initialState: false)
        var deadlines: [DispatchWorkItem] = []
        if let timeout {
            let terminate = DispatchWorkItem {
                timedOut.withLock { $0 = true }
                kill(-processGroup, SIGTERM)
            }
            let forceKill = DispatchWorkItem { kill(-processGroup, SIGKILL) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: terminate)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout + killGracePeriod, execute: forceKill)
            deadlines = [terminate, forceKill]
        }
        let watcher = onOutput.map { OutputWatcher(file: stdoutURL, report: $0) }
        watcher?.start()
        var status: Int32 = 0
        while waitpid(spawned, &status, 0) == -1, errno == EINTR {}
        watcher?.stop()
        deadlines.forEach { $0.cancel() }
        let didTimeOut = timedOut.withLock { $0 }
        if didTimeOut {
            kill(-processGroup, SIGKILL)
        }
        let signal = status & 0x7f
        let exitCode = signal == 0 ? (status >> 8) & 0xff : signal

        return ProcessResult(
            exitCode: exitCode,
            stdout: (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? "",
            stderr: (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? "",
            timedOut: didTimeOut
        )
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
